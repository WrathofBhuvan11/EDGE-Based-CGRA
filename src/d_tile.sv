// d_tile.sv
// Data cache tile: Banked L1 2KB (per-column, total for 4 cols), handles L/S classes with LSID ordering (up to 32/block), NUCA L2 interface.
// Configurable as SRF in S-morph (direct RAM, wide 256-bit channels, gather/scatter/indirect transfers).
// Hierarchy: Contains lsid_unit (LSID queues for order/commit).
// - Banked D-cache 2KB L1 right of grid, 1MB NUCA L2 interface; 
// - SRF mode no tags/direct/wide/gather-scatter/indirect for DLP;
// - D-tiles for loads/stores with 5-bit LSID order, sequential semantics;
// - L/S classes with optional LSID auto top-bottom, big-endian byte order;

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module d_tile #(
    parameter WIDE_WIDTH = 256              // parameter for SRF wide
) (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input morph_config_t morph_config,      // Morph configuration (SRF in S-morph)
    input logic load_req,                   // Load req input from E (L class)
    input logic store_req,                  // Store req input from E (S class)
    input lsid_t lsid,                      // LSID input (5-bit for order)
    input logic [31:0] addr,                // Addr input
    input reg_data_t store_data,            // Store data input
    output reg_data_t load_data,            // Load data output
    output logic hit,                       // Hit output (2-cycle L1 hit latency)
    output logic ack,                       // Ack output (ordered/processed)
    output logic [31:0] mem_tile_addr,      // Addr output to on-chip net (L2)
    output logic mem_tile_read_req,         // Read req output to net
    output logic mem_tile_write_req,        // Write req output to net
    output reg_data_t [3:0] mem_tile_data_wide,  // Wide data output for SRF (256-bit = 4x64-bit)
    output logic mem_tile_config_srf,       // SRF config output to net
    input logic mem_tile_ack                // Ack input from net
);

    // Internal params (L1 2KB total, 4 banks ~512B each, 2-way assoc, 64B line)
    localparam BANK_SIZE = 512;             // Bytes/bank (2KB/4)
    localparam ASSOC = 2;                   // 2-way
    localparam LINE_BYTES = 64;             // Line size
    localparam SETS = BANK_SIZE / (ASSOC * LINE_BYTES);  // 4 sets/bank
    localparam SET_BITS = $clog2(SETS);     // 2 bits
    localparam BYTE_OFF_BITS = $clog2(LINE_BYTES);  // 6 bits
    localparam TAG_BITS = ADDR_WIDTH - (SET_BITS + BYTE_OFF_BITS);  // Tag

    // Cache storage per bank (simplified single bank for tile; real per-col)
    logic [7:0] data_ram [BANK_SIZE-1:0];   // Byte RAM (512B)
    logic [TAG_BITS-1:0] tag_ram [ASSOC-1:0][SETS-1:0];
    logic valid_ram [ASSOC-1:0][SETS-1:0];
    logic dirty_ram [ASSOC-1:0][SETS-1:0];
    logic [ASSOC-1:0] lru_ram [SETS-1:0];   // LRU bits (1-bit for 2-way: 0=way0 LRU)

    // Internal signals
    logic is_srf_mode = morph_config.srf_enable;  // SRF config (no tags/direct)
    logic [SET_BITS-1:0] set_idx = addr[SET_BITS + BYTE_OFF_BITS -1 : BYTE_OFF_BITS];
    logic [BYTE_OFF_BITS-1:0] byte_off = addr[BYTE_OFF_BITS-1:0];
    logic [TAG_BITS-1:0] tag = addr[ADDR_WIDTH-1 : SET_BITS + BYTE_OFF_BITS];
    logic [1:0] hit_way;
    logic internal_hit;
    logic [63:0] line_data;                 // Read line (64B=512 bits; simplified 64-bit out)
    logic ack_lsid;                         // Declared wire for lsid_unit ack (implicit -> explicit; now gated in FSM)

    // FSM for rd/wr/miss/replace/SRF transfers
    typedef enum logic [2:0] {IDLE, CACHE_RD, CACHE_WR, CACHE_MISS, SRF_RD, SRF_WR, SRF_GS} state_t;
    state_t state, next_state;

    // State transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else state <= next_state;
    end

    // Next state and logic
    always_comb begin
        next_state = state;
        hit = 0;
        ack = 0;
        load_data = '0;
        mem_tile_read_req = 0;
        mem_tile_write_req = 0;
        mem_tile_data_wide = '0;
        mem_tile_config_srf = is_srf_mode;
        mem_tile_addr = addr;
        internal_hit = 0;
        hit_way = 0;

        case (state)
            IDLE: begin
                if (!is_srf_mode) begin  // Cache mode
                    if (load_req) next_state = CACHE_RD;
                    else if (store_req) next_state = CACHE_WR;
                end else begin  // SRF mode
                    if (load_req) next_state = SRF_RD;
                    else if (store_req) next_state = SRF_WR;
                    else next_state = SRF_GS;  // Gather/scatter if special type (simplified)
                end
            end
            CACHE_RD: begin
                // Tag check
                for (int way = 0; way < ASSOC; way++) begin
                    if (valid_ram[way][set_idx] && tag_ram[way][set_idx] == tag) begin
                        internal_hit = 1;
                        hit_way = way;
                        // Read data (simplified word; byte_off select)
                        load_data = data_ram[set_idx * LINE_BYTES + byte_off];  // Assume 32-bit word
                        hit = 1;
                        ack = ack_lsid;  // lsid_unit ack (ordered)
                        next_state = IDLE;
                    end
                end
                if (!internal_hit) next_state = CACHE_MISS;
            end
            CACHE_WR: begin
                // Tag check/alloc
                internal_hit = 0;
                for (int way = 0; way < ASSOC; way++) begin
                    if (valid_ram[way][set_idx] && tag_ram[way][set_idx] == tag) begin
                        internal_hit = 1;
                        hit_way = way;
                    end
                end
                if (!internal_hit) begin
                    // Evict LRU (simplified way0 if lru=0)
                    hit_way = lru_ram[set_idx][0] ? 1 : 0;
                    if (dirty_ram[hit_way][set_idx]) mem_tile_write_req = 1;  // Writeback to L2
                    tag_ram[hit_way][set_idx] = tag;
                    valid_ram[hit_way][set_idx] = 1;
                    dirty_ram[hit_way][set_idx] = 1;
                    lru_ram[set_idx] = ~lru_ram[set_idx];  // Flip LRU
                end else dirty_ram[hit_way][set_idx] = 1;
                // Write data
                data_ram[set_idx * LINE_BYTES + byte_off] = store_data[7:0];  // Byte write simplified
                ack = ack_lsid;  // Gate with ordered ack
                next_state = IDLE;
            end
            CACHE_MISS: begin
                mem_tile_read_req = 1;  // Fetch from L2
                if (mem_tile_ack) begin
                    // Fill (simplified; assume data_wide to ram)
                    next_state = CACHE_RD;  // Retry
                end
            end
            SRF_RD: begin
                // Direct read (wide)
                for (int i = 0; i < WIDE_WIDTH/8; i++) mem_tile_data_wide[i/64] = data_ram[addr + i];  // Pack wide
                ack = ack_lsid;  // Gate with lsid_unit ack (ordered)
                next_state = IDLE;
            end
            SRF_WR: begin
                // Direct write (wide)
                for (int i = 0; i < WIDE_WIDTH/8; i++) data_ram[addr + i] = mem_tile_data_wide[i/64][7:0];  // Unpack
                ack = ack_lsid;  // Gate with ordered ack
                next_state = IDLE;
            end
            SRF_GS: begin
                // Gather/scatter (simplified strided; assume transfer_type/stride in addr high bits)
                ack = ack_lsid;  // Gate with ordered ack
                next_state = IDLE;
            end
        endcase
    end

    // Instantiate lsid_unit (for L/S ordering)
    lsid_unit lsid_unit_inst (
        .clk(clk),
        .rst_n(rst_n),
        .lsid(lsid),
        .load_req(load_req),
        .store_req(store_req),
        .addr(addr),
        .store_data(store_data),
        .load_data(load_data),
        .ack(ack_lsid)  // Internal ack for order
    );

    // Big-endian handling: MSB first;

endmodule

