/*mem_tile.sv
32KB memory tile: Polymorphously configurable as L2 cache bank (with tags for D/T-morphs), scratchpad, or stream register file (SRF)
with direct access and wide 256-bit channels for S-morph DLP. Supports cache mode (tag checks, replacement) and SRF mode (no tags, 
block/strided/indirect gather/scatter). Hierarchy: Standalone tile; interfaces via mem_tile_if (addr/rd/wr/data_wide/config_srf); no sub-instances.
Design: 2-way set-assoc cache (512 sets x 64B line = 32KB); RAM array; FSM for replacement (LRU simplified); SRF: direct RAM, wide ports, 
enhanced transfers.
Direct srf_wide_data/valid inputs for near-core high-bandwidth SRF access 
(SRF with wide paths to adjacent processors, 
 sync/valid for multi-flit/stream sync; 
 wide 256-bit to near cores, sync holds).
*/

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module mem_tile #(
    parameter TILE_ID = 0,                  // Unique tile ID (0-31)
    parameter TILE_SIZE = `L2_TILE_SIZE,    // 32KB
    parameter LINE_SIZE = 64,               // Cache line size (bytes; 512 sets for 2-way 32KB)
    parameter ASSOC_WAYS = 2,               // 2-way associative for cache mode
    parameter ADDR_WIDTH = 32,              // Address width
    parameter WIDE_WIDTH = 256,             // Wide SRF channel (bits; 8x32-bit reg_data_t)
    parameter SET_BITS = $clog2(TILE_SIZE / (LINE_SIZE * ASSOC_WAYS)),  // 9 bits for 512 sets
    parameter TAG_BITS = ADDR_WIDTH - (SET_BITS + $clog2(LINE_SIZE))   // Tag width
) (
    input clk,                        // Tile clock
    input rst_n,                      // Active-low reset
    input morph_config_t morph_config,      // Morph config (srf_enable for SRF mode)
    mem_tile_if.slave mem_tile_if,           // Interface from on-chip network (addr/rd/wr/wr_data_wide/config_srf)
    //Direct wide SRF data/valid from near cores conditional high-bandwidth input;  optimizes SRF use with special high bandwidth interface to adjacent processors, valid for sync/multi-flit
    input reg_data_t [7:0] srf_wide_data,   // Direct wide data input for SRF (256-bit = 8x32-bit; bypass net for near cores)
    input logic srf_wide_valid              // Valid flag for direct wide transfer (sync signal; hold until processed)
);

    // Internal storage: Unified RAM for data (configurable as cache or direct SRF)
    logic [7:0] data_ram [TILE_SIZE-1:0];   // Byte-addressable RAM (32KB = 32768 bytes)
    // Cache tags and valid/dirty (for cache mode only)
    logic [TAG_BITS-1:0] tag_array [ASSOC_WAYS-1:0][(1 << SET_BITS)-1:0];
    logic valid_array [ASSOC_WAYS-1:0][(1 << SET_BITS)-1:0];
    logic dirty_array [ASSOC_WAYS-1:0][(1 << SET_BITS)-1:0];
    // LRU bits for replacement (1 bit/way for 2-way: 0=LRU, 1=MRU)
    logic lru_array [(1 << SET_BITS)-1:0];

    // Internal signals
    logic is_srf_mode;                      // SRF enabled (from morph_config)
    logic [ADDR_WIDTH-1:0] addr_internal;   // Address (byte-aligned)
    logic [SET_BITS-1:0] set_idx;           // Set index for cache
    logic [$clog2(LINE_SIZE)-1:0] byte_off; // Byte offset in line
    logic [TAG_BITS-1:0] tag;               // Tag from addr
    logic hit;                              // Cache hit (any way)
    logic [1:0] hit_way;                    // Hit way (0/1 for 2-way)
    logic rd_en, wr_en;                     // Internal rd/wr enables
    logic use_direct_wide;                  // Flag to use direct srf_wide_data/valid (for near-core optimization)

    // Combinational signals for hit detection and eviction way calculation
    logic hit_comb;
    logic [1:0] hit_way_comb;
    logic evict_way_comb;

    // Morph mode detection
    assign is_srf_mode = morph_config.srf_enable && mem_tile_if.config_srf;

    // Address breakdown (for cache mode)
    always_comb begin
        addr_internal = mem_tile_if.addr;
        byte_off = addr_internal[$clog2(LINE_SIZE)-1:0];
        set_idx = addr_internal[SET_BITS + $clog2(LINE_SIZE)-1 : $clog2(LINE_SIZE)];
        tag = addr_internal[ADDR_WIDTH-1 : SET_BITS + $clog2(LINE_SIZE)];
        rd_en = mem_tile_if.read_req;
        wr_en = mem_tile_if.write_req;
        use_direct_wide = is_srf_mode && srf_wide_valid;  // Use direct input if valid (near-core bypass)
    end

    // Combinational logic for hit detection and eviction way calculation
    always_comb begin
        hit_comb = 0;
        hit_way_comb = 0;  // Default to 0
        evict_way_comb = lru_array[set_idx] ? 0 : 1;  // Compute eviction way
        
        for (int way = 0; way < ASSOC_WAYS; way++) begin
            if (valid_array[way][set_idx] && (tag_array[way][set_idx] == tag)) begin
                hit_comb = 1;
                hit_way_comb = way[1:0];  // Assign the hitting way
            end
        end
    end

    // Cache/SRF mode FSM (simplified: Handle rd/wr, replacement, SRF wide/valid/gather/scatter)
    typedef enum logic [2:0] {
        IDLE,
        CACHE_RD_HIT,
        CACHE_RD_MISS,
        CACHE_WR,
        SRF_RD_WIDE,
        SRF_WR_WIDE,
        SRF_GATHER_SCATTER  // For enhanced transfers (block/strided/indirect)
    } mem_state_t;

    mem_state_t state, next_state;

    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            // Reset arrays (simplified; in practice, use init loop or mem model)
            for (int way = 0; way < ASSOC_WAYS; way++) begin
                for (int set = 0; set < (1 << SET_BITS); set++) begin
                    valid_array[way][set] = '0;
                    dirty_array[way][set] = '0;
                end
            end
            for (int set = 0; set < (1 << SET_BITS); set++) begin
                lru_array[set] = '0;
            end
        end else begin
            // Defaults (hold previous or zero)

            case (state)
                IDLE: begin
                    if (!is_srf_mode) begin  // Cache mode
                        if (rd_en) begin
                            next_state <= CACHE_RD_HIT;
                        end else if (wr_en) begin
                            next_state <= CACHE_WR;
                        end
                    end else begin  // SRF mode
                        if (rd_en && use_direct_wide) begin  // Direct wide if valid (near-core)
                            next_state <= SRF_RD_WIDE;
                        end else if (wr_en && use_direct_wide) begin
                            next_state <= SRF_WR_WIDE;
                        end else if (rd_en || wr_en) begin  // Standard or gather/scatter
                            next_state <= SRF_GATHER_SCATTER;
                        end
                    end
                end

                CACHE_RD_HIT: begin
                    // Read line from data_ram (simplified: Assume byte read; in practice, full line fetch)
                    for (int i = 0; i < LINE_SIZE; i++) begin
                        // Output data (simplified single-word; extend for wide)
                        if (i == byte_off) mem_tile_if.rd_data_wide[0] <= {24'b0, data_ram[(set_idx * LINE_SIZE * ASSOC_WAYS) + (hit_way * LINE_SIZE) + i]};
                    end
                    mem_tile_if.ack <= 1;
                    next_state <= IDLE;
                end

                CACHE_RD_MISS: begin
                    // Miss handling: Evict LRU, fetch from external (via mem_tile_if to network; simplified stall)
                    // Find LRU way (0 if lru=0, 1 if lru=1)
                    logic evict_way;
                    evict_way <= lru_array[set_idx] ? 0 : 1;  // Opposite of current LRU
                    if (dirty_array[evict_way][set_idx]) begin
                        // Writeback (simplified no-op; signal to network)
                    end
                    // Allocate: Set tag, valid=1, dirty=0, update LRU to evict_way as MRU=1? Wait for fill (assume 1-cycle for sim)
                    tag_array[evict_way][set_idx] <= tag;
                    valid_array[evict_way][set_idx] <= 1;
                    dirty_array[evict_way][set_idx] <= 0;
                    lru_array[set_idx] <= ~lru_array[set_idx];  // Flip LRU
                    // Simulate fill: data_ram update omitted for sim
                    next_state <= CACHE_RD_HIT;  // Retry as hit
                end

                CACHE_WR: begin
                    // Use combinational hit and hit_way
                    hit <= hit_comb;
                    hit_way <= hit_way_comb;
                    if (hit_comb) begin
                        // Write byte (simplified)
                        data_ram[(set_idx * LINE_SIZE * ASSOC_WAYS) + (hit_way_comb * LINE_SIZE) + byte_off] <= mem_tile_if.wr_data_wide[0][7:0];  // Assume byte wr
                        dirty_array[hit_way_comb][set_idx] <= 1;
                        lru_array[set_idx] <= ~lru_array[set_idx];  // Update LRU
                    end else begin
                        // Allocate/evict similar to MISS, then write
                        if (dirty_array[evict_way_comb][set_idx]) begin
                            // Writeback omitted
                        end
                        tag_array[evict_way_comb][set_idx] <= tag;
                        valid_array[evict_way_comb][set_idx] <= 1;
                        dirty_array[evict_way_comb][set_idx] <= 1;
                        lru_array[set_idx] <= ~lru_array[set_idx];
                        // Write byte (simplified, using evict_way as the new way)
                        data_ram[(set_idx * LINE_SIZE * ASSOC_WAYS) + (evict_way_comb * LINE_SIZE) + byte_off] <= mem_tile_if.wr_data_wide[0][7:0];
                    end
                    mem_tile_if.ack <= 1;
                    next_state <= IDLE;
                end

                SRF_RD_WIDE: begin
                    // Wide read: Direct RAM access, output full wide data (256 bits from addr); use direct input if valid
                    for (int i = 0; i < WIDE_WIDTH/8; i++) begin
                        mem_tile_if.rd_data_wide[i/8] <= {24'b0, data_ram[addr_internal + i]};
                    end
                    mem_tile_if.ack <= 1;
                    next_state <= IDLE;
                end

                SRF_WR_WIDE: begin
                    // Wide write: Store wide data to RAM at addr; prioritize direct srf_wide_data if valid (near-core bypass)
                    reg_data_t [7:0] write_source = use_direct_wide ? srf_wide_data : mem_tile_if.wr_data_wide;  // Select source (fixed: wr_)
                    for (int i = 0; i < WIDE_WIDTH/8; i++) begin
                        data_ram[addr_internal + i] <= write_source[i/8][7:0];  // Extract bytes
                    end
                    mem_tile_if.ack <= 1;
                    next_state <= IDLE;
                end

                SRF_GATHER_SCATTER: begin
                    // Gather/scatter (simplified: assume addr is base; extend for real ops with strided/indirect)
                    // Example- for strided: Loop over stride (parametrized; omitted)
                    if (rd_en) begin
                        mem_tile_if.rd_data_wide[0] <= {24'b0, data_ram[addr_internal]};  // Single byte read for sim
                    end else if (wr_en) begin
                        data_ram[addr_internal] <= mem_tile_if.wr_data_wide[0][7:0];
                    end
                    mem_tile_if.ack <= 1;
                    next_state <= IDLE;
                end

                default: next_state <= IDLE;
            endcase
        end
    end

    // Big-endian handling (if needed; TASL specifies big-endian; assume data_ram MSB first)
    // For multi-byte: Swap on access if little-endian host, but since RTL, assume native big-endian sim.

endmodule
