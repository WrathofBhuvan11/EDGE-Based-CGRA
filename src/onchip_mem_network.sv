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

    localparam TOTAL_ROUTERS = ROUTER_ROWS * ROUTER_COLS;
    localparam FLIT_TYPE = 1;               // 1=mem (addr/wide/transfer)
   
    // Router array: 1D flattened interfaces (per direction) 
    // patch fix to address Verilator feature for 2D Interfaces
    router_if north_net [TOTAL_ROUTERS-1:0] ();
    router_if south_net [TOTAL_ROUTERS-1:0] ();
    router_if east_net [TOTAL_ROUTERS-1:0] ();
    router_if west_net [TOTAL_ROUTERS-1:0] ();
    router_if local_net [TOTAL_ROUTERS-1:0] ();

    // Mapping: Cores to top-row routers (0,0) to (0,3); tiles to remaining (ID % TOTAL_ROUTERS)
    localparam int CORE_ROUTER_MAP [NUM_CORES-1:0] = '{0: 0*ROUTER_COLS + 0, 1: 0*ROUTER_COLS + 1, 2: 0*ROUTER_COLS + 2, 3: 0*ROUTER_COLS + 3};
    localparam int TILE_ROUTER_MAP [NUM_TILES-1:0] ='{
                                                         0, 
                                                         1, 
                                                         2, 
                                                         3, 
                                                         4, 
                                                         5, 
                                                         6, 
                                                         7, 
                                                         8, 
                                                         9, 
                                                         10,
                                                         11,
                                                         12,
                                                         13,
                                                         14,
                                                         15,
                                                         16,
                                                         17,
                                                         18,
                                                         19,
                                                         20,
                                                         21,
                                                         22,
                                                         23,
                                                         24,
                                                         25,
                                                         26,
                                                         27,
                                                         28,
                                                         29,
                                                         30,
                                                         31
                                                         };
    // Internal signals
    logic is_srf_mode = morph_config.srf_enable;

    // Instantiate routers: Generate 2D array with FLIT_TYPE=1
    genvar r_row, r_col;
    generate
        for (r_row = 0; r_row < ROUTER_ROWS; r_row++) begin : gen_router_rows
            for (r_col = 0; r_col < ROUTER_COLS; r_col++) begin : gen_router_cols
                localparam int RID = r_row * ROUTER_COLS + r_col;
                router #(
                    .ROUTER_ID(RID),
                    .ROUTER_COLS(ROUTER_COLS),
                    .FLIT_TYPE(FLIT_TYPE),          // 1 for mem (addr-based)
                    .BUFFER_DEPTH(BUFFER_DEPTH)
                ) router_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .is_srf_mode(is_srf_mode),
                    .north_if(north_net[RID]),
                    .south_if(south_net[RID]),
                    .east_if(east_net[RID]),
                    .west_if(west_net[RID]),
                    .local_if(local_net[RID])
                );
            end
        end
    endgenerate

    // Connect mesh links: N-S, E-W (boundary null)
    // generate (per-router comb; static unroll for const indices)
    generate
        for (genvar rr = 0; rr < ROUTER_ROWS; rr++) begin : gen_connect_rows
            for (genvar rc = 0; rc < ROUTER_COLS; rc++) begin : gen_connect_cols
                localparam int RID = rr * ROUTER_COLS + rc;
                localparam int NORTH_RID = (rr > 0) ? (rr-1) * ROUTER_COLS + rc : -1;
                localparam int SOUTH_RID = (rr < ROUTER_ROWS-1) ? (rr+1) * ROUTER_COLS + rc : -1;
                localparam int EAST_RID = (rc < ROUTER_COLS-1) ? rr * ROUTER_COLS + (rc+1) : -1;
                localparam int WEST_RID = (rc > 0) ? rr * ROUTER_COLS + (rc-1) : -1;

                always_comb begin
                    // Defaults
                    north_net[RID].flit_in = '0;
                    north_net[RID].req_in = 0;
                    north_net[RID].ack_out = 0;
                    south_net[RID].flit_out = '0;
                    south_net[RID].req_out = 0;
                    south_net[RID].ack_in = 0;
                    east_net[RID].flit_in = '0;
                    east_net[RID].req_in = 0;
                    east_net[RID].ack_out = 0;
                    west_net[RID].flit_out = '0;
                    west_net[RID].req_out = 0;
                    west_net[RID].ack_in = 0;

                    // N-S connect
                    if (NORTH_RID >= 0) begin
                        south_net[NORTH_RID].flit_in = north_net[RID].flit_out;
                        south_net[NORTH_RID].req_in = north_net[RID].req_out;
                        north_net[RID].ack_out = south_net[NORTH_RID].ack_in;
                        north_net[RID].flit_in = south_net[NORTH_RID].flit_out;
                        north_net[RID].req_in = south_net[NORTH_RID].req_out;
                        south_net[NORTH_RID].ack_out = north_net[RID].ack_in;
                    end 
                    else if (SOUTH_RID >= 0) begin
                        north_net[SOUTH_RID].flit_in = south_net[RID].flit_out;
                        north_net[SOUTH_RID].req_in = south_net[RID].req_out;
                        south_net[RID].ack_out = north_net[SOUTH_RID].ack_in;
                        south_net[RID].flit_in = north_net[SOUTH_RID].flit_out;
                        south_net[RID].req_in = north_net[SOUTH_RID].req_out;
                        north_net[SOUTH_RID].ack_out = south_net[RID].ack_in;
                    end 
                    // E-W connect
                    else if (EAST_RID >= 0) begin
                        west_net[EAST_RID].flit_in = east_net[RID].flit_out;
                        west_net[EAST_RID].req_in = east_net[RID].req_out;
                        east_net[RID].ack_out = west_net[EAST_RID].ack_in;
                        east_net[RID].flit_in = west_net[EAST_RID].flit_out;
                        east_net[RID].req_in = west_net[EAST_RID].req_out;
                        west_net[EAST_RID].ack_out = east_net[RID].ack_in;
                    end 
                    else if (WEST_RID >= 0) begin
                        east_net[WEST_RID].flit_in = west_net[RID].flit_out;
                        east_net[WEST_RID].req_in = west_net[RID].req_out;
                        west_net[RID].ack_out = east_net[WEST_RID].ack_in;
                        west_net[RID].flit_in = east_net[WEST_RID].flit_out;
                        west_net[RID].req_in = east_net[WEST_RID].req_out;
                        east_net[WEST_RID].ack_out = west_net[RID].ack_in;
                    end 
                end
            end
        end
    endgenerate

    // Connect cores to local ports (pack/unpack flits)
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c++) begin : gen_core_connect
            localparam int rid = CORE_ROUTER_MAP[c];
            // Pack core to flit (to local in) - REQUEST from core to net
            always_comb begin
                generic_flit_t core_flit;
                core_flit.addr = core_mem_if[c].addr;
                core_flit.is_read = core_mem_if[c].read_req;
                core_flit.is_wide = core_mem_if[c].data_wide_valid && is_srf_mode;
                core_flit.transfer_type = is_srf_mode ? 1 : 0;  // Example: 1=block; extend for strided/indirect
                core_flit.payload_size = core_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;  // Bytes
                core_flit.data = core_flit.is_wide ? core_mem_if[c].wr_data_wide : core_mem_if[c].store_data;
                core_flit.last_flit = core_flit.payload_size <= FLIT_SIZE / 8;  // Single if small
                core_flit.ipriority = core_flit.is_wide ? 1 : 0;
                core_flit.src_core = c;

                local_net[rid].flit_in = core_flit;
                local_net[rid].req_in = core_mem_if[c].read_req || core_mem_if[c].write_req;
                core_mem_if[c].ack = local_net[rid].ack_out;  // correct: ack is output for slave modport on core_mem_if
            end

            // Unpack from local out to core (response) - RESPONSE from net to core
            always_comb begin
                generic_flit_t resp_flit;
                resp_flit = '0;  // Default
                if (local_net[rid].req_out) begin
                    resp_flit = local_net[rid].flit_out;
                    if (resp_flit.src_core == c) begin  // Route back to src core
                        core_mem_if[c].rd_data_wide = resp_flit.is_wide ? resp_flit.data : '0;  // Unpack
                        local_net[rid].ack_in = core_mem_if[c].ack;  // Ack from core to net (slave: output rd/ack)
                    end else begin
                        // Defaults for no match (no latch)
                        core_mem_if[c].rd_data_wide = '0;
                        local_net[rid].ack_in = 0;
                    end
                end else begin
                    // Defaults for no req_out (no latch)
                    core_mem_if[c].rd_data_wide = '0;
                    local_net[rid].ack_in = 0;
                end
            end
        end
    endgenerate

    // Connect tiles to local ports (unpack/pack flits)
    genvar t;
    generate
        for (t = 0; t < NUM_TILES; t++) begin : gen_tile_connect
            localparam int rid = TILE_ROUTER_MAP[t];
            // Unpack from local out to tile - REQUEST from net to tile
            always_comb begin
                generic_flit_t req_flit;
                req_flit = '0;  // Default
		        /// local_net = '0;
                if (local_net[rid].req_out) begin
                    req_flit = local_net[rid].flit_out;
                    tile_mem_if[t].addr = req_flit.addr;
                    tile_mem_if[t].read_req = req_flit.is_read;
                    tile_mem_if[t].write_req = !req_flit.is_read;
                    tile_mem_if[t].wr_data_wide = req_flit.is_wide ? req_flit.data : '0;
                    tile_mem_if[t].data_wide_valid = req_flit.is_wide;
                    tile_mem_if[t].store_data = req_flit.data;
                    tile_mem_if[t].config_srf = is_srf_mode;
                    local_net[rid].ack_in = tile_mem_if[t].ack;  // Read ack (input for master) to drive net ack_in
                end
                else begin
                    tile_mem_if[t].addr = '0;
                    tile_mem_if[t].read_req = 0;
                    tile_mem_if[t].write_req = 0;
                    tile_mem_if[t].wr_data_wide = '0;
                    tile_mem_if[t].data_wide_valid = 0;
                    tile_mem_if[t].store_data = '0;
                    tile_mem_if[t].config_srf = 0;
                    local_net[rid].ack_in = '0;
                end
            end

            // Pack tile response to local in (for return path) - RESPONSE from tile to net
            always_comb begin
                generic_flit_t resp_flit;
                resp_flit.addr = tile_mem_if[t].addr;  // Return to src
                resp_flit.is_read = 0;  // Response
                resp_flit.is_wide = tile_mem_if[t].data_wide_valid && is_srf_mode;
                resp_flit.transfer_type = 0;
                resp_flit.payload_size = resp_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;
                resp_flit.data = tile_mem_if[t].rd_data_wide;  // Read rd_data_wide (input) to pack data
                resp_flit.last_flit = 1;
                resp_flit.ipriority = 0;
                resp_flit.src_core = 0;  // Set from req (tracked in tile; simplified dummy)

                local_net[rid].flit_in = resp_flit;
                local_net[rid].req_in = tile_mem_if[t].ack && tile_mem_if[t].read_req;  // Response on read
                //local_net[ext_rid].ack_in = tile_mem_if[t].ack; 
            end
        end
    endgenerate

    // External mem connect (to bottom-right router)
    localparam int EXT_ROUTER_ID = (ROUTER_ROWS-1) * ROUTER_COLS + (ROUTER_COLS-1);
    localparam int ext_rid = EXT_ROUTER_ID;

    // Pack ext to flit (to local in) - REQUEST to external
    always_comb begin
        generic_flit_t ext_flit;
        ext_flit.addr = ext_mem_if.addr;
        ext_flit.is_read = ext_mem_if.read_req;
        ext_flit.is_wide = 0;  // External not wide
        ext_flit.transfer_type = 0;
        ext_flit.payload_size = FLIT_SIZE / 8;
        ext_flit.data = ext_mem_if.store_data;
        ext_flit.last_flit = 1;
        ext_flit.ipriority = 0;
        ext_flit.src_core = 0;  // Dummy

        local_net[ext_rid].flit_in = ext_flit;
        local_net[ext_rid].req_in = ext_mem_if.read_req || ext_mem_if.write_req;
        //local_net[ext_rid].ack_in = ext_mem_if.ack; 
    end

    // Unpack from local out to ext (response) - RESPONSE from external
    always_comb begin
        generic_flit_t ext_resp;
        ext_resp = '0;  // Default
        if (local_net[ext_rid].req_out) begin
            ext_resp = local_net[ext_rid].flit_out;
            //ext_mem_if.rd_data_wide = ext_resp.is_wide ? ext_resp.data : '0;  // Unpack if needed (but ext not wide)
            local_net[ext_rid].ack_in = ext_mem_if.ack;  
        end else begin
            local_net[ext_rid].ack_in = 0;
        end
    end

endmodule
