// onchip_mem_network.sv
// Switched 2D interconnection network: Connects cores to 32 memory tiles for scalable access to L2/scratchpad/SRF.
// Supports standard cache requests and enhanced S-morph transfers (wide 256-bit channels, block/strided/indirect gather/scatter).
// Topology: 2D mesh with routers (XY routing, wormhole for wide/flits, basic arbitration; for deadlock avoidance).
// Hierarchy: contains router array for point-to-point routing.
// - switched 2D network, less wiring than dedicated; 
// - SRF wide channels 256-bit/row, gather/scatter/indirect; 
// - D-tiles to memory implied),
// - mem ops via L/S but network for off-core.
// Design: Mesh routers (5-port: N/S/E/W/Local; XY dim-order routing to avoid deadlock base; arbiter RR; flit buffers depth 4).

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module onchip_mem_network #(
    parameter NUM_CORES = 4,                // Prototype: 4 polymorphous cores
    parameter NUM_TILES = `NUM_L2_TILES,    // Memory tiles (32) for 1MB on-chip memory
    parameter ROUTER_ROWS = 8,              // Mesh rows (scalable; e.g., 8 for balanced layout)
    parameter ROUTER_COLS = 4,              // Mesh cols (total routers: 32, matching tiles + extras)
    parameter ADDR_WIDTH = 32,              // Address width
    parameter WIDE_WIDTH = 256,             // SRF wide data width (bits)
    parameter FLIT_SIZE = 64,               // Flit size (bits; for multi-flit packets)
    parameter BUFFER_DEPTH = 4              // FIFO depth per input port
) (
    input clk,                                  // Network clock
    input rst_n,                                // Active-low reset
    mem_tile_if.slave core_mem_if [NUM_CORES-1:0],  // From cores (net as slave: inputs reqs/wr, outputs rd/ack)
    mem_tile_if.master tile_mem_if [NUM_TILES-1:0],  // To memory tiles (net as master: outputs reqs/wr, inputs rd/ack)
    mem_tile_if.master ext_mem_if,            // To external memory (net as master: outputs reqs/wr, inputs rd/ack)
    input morph_config_t morph_config       // Morph config (srf_enable, srf_banks)
);

    localparam TOTAL_ROUTERS = ROUTER_ROWS * ROUTER_COLS;  // Total routers in mesh (e.g., 32 for 8x4)
    localparam FLIT_TYPE = 1;               // 1=mem (addr/wide/transfer; distinguishes from operand net FLIT_TYPE=0)
   
    // Router array: 1D flattened interfaces (per direction) 
    // patch fix to address Verilator feature for 2D Interfaces (flattened to avoid multi-dim interface arrays)
    router_if north_net [TOTAL_ROUTERS-1:0] ();  // North direction interfaces for each router
    router_if south_net [TOTAL_ROUTERS-1:0] ();  // South direction
    router_if east_net [TOTAL_ROUTERS-1:0] ();   // East direction
    router_if west_net [TOTAL_ROUTERS-1:0] ();   // West direction
    router_if local_net [TOTAL_ROUTERS-1:0] ();  // Local (to core/tile/external) direction

    // Mapping: Cores to top-row routers (0,0) to (0,3); tiles to remaining (ID % TOTAL_ROUTERS)
    // This maps 4 cores to row 0, tiles to rows 1-7 (design choice for locality; cores fetch from nearby tiles)
    localparam int CORE_ROUTER_MAP [NUM_CORES-1:0] = '{0: 0*ROUTER_COLS + 0, 1: 0*ROUTER_COLS + 1, 2: 0*ROUTER_COLS + 2, 3: 0*ROUTER_COLS + 3};
    localparam int TILE_ROUTER_MAP [NUM_TILES-1:0] = '{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31};
    
    // Internal signals
    logic is_srf_mode = morph_config.srf_enable;  // Derived from morph_config; enables SRF mode for wide transfers (S-morph)

    // Instantiate routers: Generate 2D array with FLIT_TYPE=1
    // Each router is a 5-port XY router (router.sv); instantiated in a flattened loop for verilator compatibility
    genvar r_row, r_col;
    generate
        for (r_row = 0; r_row < ROUTER_ROWS; r_row++) begin : gen_router_rows  // Outer loop for rows
            for (r_col = 0; r_col < ROUTER_COLS; r_col++) begin : gen_router_cols  // Inner loop for columns
                localparam int RID = r_row * ROUTER_COLS + r_col;  // Unique router ID (0 to TOTAL_ROUTERS-1)
                router #( 
                    .ROUTER_ID(RID),  // Pass ID for internal coord calculation (CURR_ROW/COL)
                    .ROUTER_COLS(ROUTER_COLS),  // For XY routing dimension
                    .FLIT_TYPE(FLIT_TYPE),          // 1 for mem (addr-based routing)
                    .BUFFER_DEPTH(BUFFER_DEPTH)  // Input buffer size
                ) router_inst (
                    .clk(clk),  
                    .rst_n(rst_n), 
                    .is_srf_mode(is_srf_mode),  // Enable priority for wide flits in S-morph
                    .north_if(north_net[RID]),  // Connect north interface
                    .south_if(south_net[RID]),  // South
                    .east_if(east_net[RID]),    // East
                    .west_if(west_net[RID]),    // West
                    .local_if(local_net[RID])   // Local (to attached core/tile)
                );
            end
        end
    endgenerate

    // Mesh wiring: Connect routers internally (N-S, E-W edges handled with defaults)
    generate
        for (r_row = 0; r_row < ROUTER_ROWS; r_row++) begin : gen_wiring_rows  // Loop over rows for wiring
            for (r_col = 0; r_col < ROUTER_COLS; r_col++) begin : gen_wiring_cols  // Loop over columns
                localparam int rid = r_row * ROUTER_COLS + r_col;  // Current router ID

                // North connection (only if not top row; connect my north to northern neighbor's south)
                if (r_row > 0) begin
                    // Connect south of north neighbor to this north
                    localparam int north_rid = (r_row - 1) * ROUTER_COLS + r_col;
                    assign south_net[north_rid].flit_in = north_net[rid].flit_out;
                    assign south_net[north_rid].req_in = north_net[rid].req_out;
                    assign north_net[rid].ack_out = south_net[north_rid].ack_in;
                    assign north_net[rid].flit_in = south_net[north_rid].flit_out;
                    assign north_net[rid].req_in = south_net[north_rid].req_out;
                    assign south_net[north_rid].ack_out = north_net[rid].ack_in;
                end else begin
                    // Top row: No north connection
                    assign north_net[rid].flit_in = '0;
                    assign north_net[rid].req_in = 0;
                    assign north_net[rid].ack_out = 0;  // No ack needed
                end

                // South connection (only if not bottom row; connect my south to southern neighbor's north)
                if (r_row < ROUTER_ROWS - 1) begin
                    // Connect north of south neighbor to this south
                    localparam int south_rid = (r_row + 1) * ROUTER_COLS + r_col;
                    assign north_net[south_rid].flit_in = south_net[rid].flit_out;
                    assign north_net[south_rid].req_in = south_net[rid].req_out;
                    assign south_net[rid].ack_out = north_net[south_rid].ack_in;
                    assign south_net[rid].flit_in = north_net[south_rid].flit_out;
                    assign south_net[rid].req_in = north_net[south_rid].req_out;
                    assign north_net[south_rid].ack_out = south_net[rid].ack_in;
                end else begin
                    // Bottom row: No south connection
                    assign south_net[rid].flit_in = '0;
                    assign south_net[rid].req_in = 0;
                    assign south_net[rid].ack_out = 0;
                end

                // East connection (only if not rightmost column; connect my east to eastern neighbor's west)
                if (r_col < ROUTER_COLS - 1) begin
                    // Connect west of east neighbor to this east
                    localparam int east_rid = r_row * ROUTER_COLS + (r_col + 1);
                    assign west_net[east_rid].flit_in = east_net[rid].flit_out;
                    assign west_net[east_rid].req_in = east_net[rid].req_out;
                    assign east_net[rid].ack_out = west_net[east_rid].ack_in;
                    assign east_net[rid].flit_in = west_net[east_rid].flit_out;
                    assign east_net[rid].req_in = west_net[east_rid].req_out;
                    assign west_net[east_rid].ack_out = east_net[rid].ack_in;
                end else begin
                    // Right edge: No east connection
                    assign east_net[rid].flit_in = '0;
                    assign east_net[rid].req_in = 0;
                    assign east_net[rid].ack_out = 0;
                end

                // West connection (only if not leftmost column; connect my west to western neighbor's east)
                if (r_col > 0) begin
                    // Connect east of west neighbor to this west
                    localparam int west_rid = r_row * ROUTER_COLS + (r_col - 1);
                    assign east_net[west_rid].flit_in = west_net[rid].flit_out;
                    assign east_net[west_rid].req_in = west_net[rid].req_out;
                    assign west_net[rid].ack_out = east_net[west_rid].ack_in;
                    assign west_net[rid].flit_in = east_net[west_rid].flit_out;
                    assign west_net[rid].req_in = east_net[west_rid].req_out;
                    assign east_net[west_rid].ack_out = west_net[rid].ack_in;
                end else begin
                    // Left edge: No west connection
                    assign west_net[rid].flit_in = '0;
                    assign west_net[rid].req_in = 0;
                    assign west_net[rid].ack_out = 0;
                end
            end
        end
    endgenerate

    // Connect cores: Generate for each core (pack requests to local in, unpack responses from local out)
    generate
        for (genvar c = 0; c < NUM_CORES; c++) begin : gen_cores
            localparam int rid = CORE_ROUTER_MAP[c];  // Router ID for this core

            // Pack core request to local in (REQUEST from core to net)
            // Constructs request flit from mem_tile_if.slave signals (core drives inputs)
            always_comb begin
                generic_flit_t req_flit;
                req_flit.addr = core_mem_if[c].addr;  // Address from core
                req_flit.is_read = core_mem_if[c].read_req;  // Load
                req_flit.is_wide = core_mem_if[c].data_wide_valid && is_srf_mode;  // Wide for SRF
                req_flit.transfer_type = 0;  // Default (extend for gather/scatter)
                req_flit.payload_size = req_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;  // Payload bytes
                req_flit.data = req_flit.is_wide ? core_mem_if[c].wr_data_wide : core_mem_if[c].store_data;  // Data to send (wide or std)
                req_flit.last_flit = 1;  // Single-flit assumption (TODO: multi-flit for wide)
                req_flit.ipriority = req_flit.is_wide ? 1 : 0;  // Higher priority for wide SRF
                req_flit.src_core = c;  // Source core for response routing (if needed)

                local_net[rid].flit_in = req_flit;  // Inject request flit
                local_net[rid].req_in = core_mem_if[c].read_req || core_mem_if[c].write_req;  // Assert on core req
            end

            // Unpack from local out to core (RESPONSE from net to core)
            // Deconstructs response flit for core_mem_if.slave (net drives outputs to core)
            always_comb begin
                generic_flit_t resp_flit = '0;  // Default initialization
                if (local_net[rid].req_out) begin  // If network req_out (response arriving)
                    resp_flit = local_net[rid].flit_out;  // Get flit
                    core_mem_if[c].rd_data_wide = resp_flit.is_wide ? resp_flit.data : '0;  // Unpack wide data (type mismatch note: assumes data is array-like; fix with multi-flit)
                    core_mem_if[c].ack = local_net[rid].req_out && (resp_flit.is_read == 0);  // Ack on response (is_read=0 flags resp)
                end else begin  // Idle defaults
                    core_mem_if[c].rd_data_wide = '0;
                    core_mem_if[c].ack = 0;
                end
                local_net[rid].ack_in = core_mem_if[c].ack;  // Core ack back to net (closes handshake)
            end
        end
    endgenerate

    // Connect tiles: Generate for each memory tile (unpack requests from local out, pack responses to local in)
    generate
        for (genvar t = 0; t < NUM_TILES; t++) begin : gen_tiles
            localparam int rid = TILE_ROUTER_MAP[t];  // Router ID for this tile

            // Unpack from local out to tile (REQUEST to tile)
            // Deconstructs flit for tile_mem_if.master (net drives outputs to tile)
            always_comb begin
                generic_flit_t req_flit = '0;  // Default initialization
                if (local_net[rid].req_out) begin  // If network req_out (request arriving)
                    req_flit = local_net[rid].flit_out;  // Get flit
                    tile_mem_if[t].addr = req_flit.addr;  // Addr to tile
                    tile_mem_if[t].read_req = req_flit.is_read;  // Load
                    tile_mem_if[t].write_req = !req_flit.is_read;  // Store
                    tile_mem_if[t].wr_data_wide = req_flit.is_wide ? req_flit.data : '0;  // Wide data
                    tile_mem_if[t].data_wide_valid = req_flit.is_wide;  // Valid
                    tile_mem_if[t].store_data = req_flit.data;  // Std data
                    tile_mem_if[t].config_srf = is_srf_mode;  // Config tile as SRF
                    local_net[rid].ack_in = tile_mem_if[t].ack;  // Tile ack back to net
                end else begin  // Idle defaults
                    tile_mem_if[t].addr = '0;
                    tile_mem_if[t].read_req = 0;
                    tile_mem_if[t].write_req = 0;
                    tile_mem_if[t].wr_data_wide = '0;
                    tile_mem_if[t].data_wide_valid = 0;
                    tile_mem_if[t].store_data = '0;
                    tile_mem_if[t].config_srf = 0;
                    local_net[rid].ack_in = 0;
                end
            end

            // Pack tile response to local in (RESPONSE from tile to net)
            // Constructs response flit from tile_mem_if.master (tile drives inputs to net)
            always_comb begin
                generic_flit_t resp_flit = '0;  // Default initialization
                resp_flit.addr = tile_mem_if[t].addr;  // Return addr (held by tile)
                resp_flit.is_read = 0;  // Response flag
                resp_flit.is_wide = tile_mem_if[t].data_wide_valid && is_srf_mode;  // Wide if valid
                resp_flit.transfer_type = 0;  // Default (extend for scatter/gather results)
                resp_flit.payload_size = resp_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;  // Payload bytes
                resp_flit.data = resp_flit.is_wide ? tile_mem_if[t].rd_data_wide : '0;  // Loaded data (wide array)
                resp_flit.last_flit = 1;  // Single-flit response
                resp_flit.ipriority = 0;  // Normal priority for responses
                resp_flit.src_core = 0;  // Dummy (tile doesn't track src; use addr for routing)

                local_net[rid].flit_in = resp_flit;  // Inject response flit
                local_net[rid].req_in = tile_mem_if[t].ack && tile_mem_if[t].read_req;  // Assert on tile ack for loads
            end
        end
    endgenerate

    // External mem connect (to bottom-right router)
    // Handles off-chip memory (DRAM); similar to tile but simplified (no wide, as external not SRF)
    localparam int EXT_ROUTER_ID = (ROUTER_ROWS-1) * ROUTER_COLS + (ROUTER_COLS-1);  // Bottom-right for external (design choice)
    localparam int ext_rid = EXT_ROUTER_ID;  // Router ID for external interface

    // Unpack from local out to external (REQUEST to external)
    // Deconstructs flit for external mem_if (spillover for L2 misses)
    always_comb begin
        generic_flit_t req_flit = '0;  // Default initialization
        if (local_net[ext_rid].req_out) begin  // If network req_out (miss to external)
            req_flit = local_net[ext_rid].flit_out;  // Get flit
            ext_mem_if.addr = req_flit.addr;  // Addr to external
            ext_mem_if.read_req = req_flit.is_read;  // Load
            ext_mem_if.write_req = !req_flit.is_read;  // Store
            ext_mem_if.wr_data_wide = req_flit.is_wide ? req_flit.data : '0;  // Wide (though external may not support)
            ext_mem_if.data_wide_valid = req_flit.is_wide;  // Valid
            ext_mem_if.store_data = req_flit.data;  // Std data
            ext_mem_if.config_srf = is_srf_mode;  // Config (external may ignore)
            local_net[ext_rid].ack_in = ext_mem_if.ack;  // External ack back to net
        end else begin  // Idle defaults
            ext_mem_if.addr = '0;
            ext_mem_if.read_req = 0;
            ext_mem_if.write_req = 0;
            ext_mem_if.wr_data_wide = '0;
            ext_mem_if.data_wide_valid = 0;
            ext_mem_if.store_data = '0;
            ext_mem_if.config_srf = 0;
            local_net[ext_rid].ack_in = 0;
        end
    end

    // Pack external response to local in (for return path) - RESPONSE from external to net
    // Constructs response flit; uses first element of rd_data_wide since external not wide
    always_comb begin
        generic_flit_t resp_flit = '0;  // Default initialization
        resp_flit.addr = ext_mem_if.addr;  // Return addr
        resp_flit.is_read = 0;  // Response flag
        resp_flit.is_wide = 0;  // External not wide (simplified)
        resp_flit.transfer_type = 0;  // Default
        resp_flit.payload_size = FLIT_SIZE / 8;  // Std flit size
        resp_flit.data = ext_mem_if.rd_data_wide[0];  // Use first element (array[7:0], but external may be scalar)
        resp_flit.last_flit = 1;  // Single-flit
        resp_flit.ipriority = 0;  // Normal
        resp_flit.src_core = 0;  // Dummy

        local_net[ext_rid].flit_in = resp_flit;  // Inject response
        local_net[ext_rid].req_in = ext_mem_if.ack && ext_mem_if.read_req;  // Assert on external ack for loads
    end

endmodule
