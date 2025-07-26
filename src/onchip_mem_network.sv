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
    parameter NUM_CORES = 4,                // Cores connected (prototype: 4)
    parameter NUM_TILES = `NUM_L2_TILES,    // Memory tiles (32)
    parameter ROUTER_ROWS = 8,              // Mesh rows (scalable; e.g., 8 for balanced layout)
    parameter ROUTER_COLS = 4,              // Mesh cols (total routers: 32, matching tiles + extras)
    parameter ADDR_WIDTH = 32,              // Address width
    parameter WIDE_WIDTH = 256,             // SRF wide data width (bits)
    parameter FLIT_SIZE = 64,               // Flit size (bits; for multi-flit packets)
    parameter BUFFER_DEPTH = 4              // FIFO depth per input port
) (
    input clk,                                  // Network clock
    input rst_n,                                // Active-low reset
    mem_tile_if.core core_mem_if [NUM_CORES-1:0],  // From cores (rd/wr/addr/data_wide)
    mem_tile_if.tile tile_mem_if [NUM_TILES-1:0],  // To memory tiles
    mem_tile_if.core ext_mem_if,            // To external memory (single channel)
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
                                                         0: 1*ROUTER_COLS + 0,
                                                         1: 1*ROUTER_COLS + 1,
                                                         2: 1*ROUTER_COLS + 2,
                                                         3: 1*ROUTER_COLS + 3,
                                                         4: 2*ROUTER_COLS + 0,
                                                         5: 2*ROUTER_COLS + 1,
                                                         6: 2*ROUTER_COLS + 2,
                                                         7: 2*ROUTER_COLS + 3,
                                                         8: 3*ROUTER_COLS + 0,
                                                         9: 3*ROUTER_COLS + 1,
                                                         10: 3*ROUTER_COLS + 2,
                                                         11: 3*ROUTER_COLS + 3,
                                                         12: 4*ROUTER_COLS + 0,
                                                         13: 4*ROUTER_COLS + 1,
                                                         14: 4*ROUTER_COLS + 2,
                                                         15: 4*ROUTER_COLS + 3,
                                                         16: 5*ROUTER_COLS + 0,
                                                         17: 5*ROUTER_COLS + 1,
                                                         18: 5*ROUTER_COLS + 2,
                                                         19: 5*ROUTER_COLS + 3,
                                                         20: 6*ROUTER_COLS + 0,
                                                         21: 6*ROUTER_COLS + 1,
                                                         22: 6*ROUTER_COLS + 2,
                                                         23: 6*ROUTER_COLS + 3,
                                                         24: 7*ROUTER_COLS + 0,
                                                         25: 7*ROUTER_COLS + 1,
                                                         26: 7*ROUTER_COLS + 2,
                                                         27: 7*ROUTER_COLS + 3,
                                                         28: 8*ROUTER_COLS + 0,
                                                         29: 8*ROUTER_COLS + 1,
                                                         30: 8*ROUTER_COLS + 2,
                                                         31: 8*ROUTER_COLS + 3
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
    always_comb begin
        for (int rr = 0; rr < ROUTER_ROWS; rr++) begin
            for (int rc = 0; rc < ROUTER_COLS; rc++) begin
                int rid = rr * ROUTER_COLS + rc;
                int north_rid = (rr > 0) ? (rr-1) * ROUTER_COLS + rc : -1;
                int south_rid = (rr < ROUTER_ROWS-1) ? (rr+1) * ROUTER_COLS + rc : -1;
                int east_rid = (rc < ROUTER_COLS-1) ? rr * ROUTER_COLS + (rc+1) : -1;
                int west_rid = (rc > 0) ? rr * ROUTER_COLS + (rc-1) : -1;

                // N-S connect
                if (north_rid >= 0) begin
                    south_net[north_rid].flit_in = north_net[rid].flit_out;
                    south_net[north_rid].req_in = north_net[rid].req_out;
                    north_net[rid].ack_out = south_net[north_rid].ack_in;
                    north_net[rid].flit_in = south_net[north_rid].flit_out;
                    north_net[rid].req_in = south_net[north_rid].req_out;
                    south_net[north_rid].ack_out = north_net[rid].ack_in;
                end else begin
                    north_net[rid].flit_in = '0;
                    north_net[rid].req_in = 0;
                    north_net[rid].ack_out = 0;
                end
                if (south_rid < 0) begin
                    south_net[rid].flit_out = '0;
                    south_net[rid].req_out = 0;
                    south_net[rid].ack_in = 0;
                end
                // E-W connect
                if (east_rid >= 0) begin
                    west_net[east_rid].flit_in = east_net[rid].flit_out;
                    west_net[east_rid].req_in = east_net[rid].req_out;
                    east_net[rid].ack_out = west_net[east_rid].ack_in;
                    east_net[rid].flit_in = west_net[east_rid].flit_out;
                    east_net[rid].req_in = west_net[east_rid].req_out;
                    west_net[east_rid].ack_out = east_net[rid].ack_in;
                end else begin
                    east_net[rid].flit_in = '0;
                    east_net[rid].req_in = 0;
                    east_net[rid].ack_out = 0;
                end
                if (west_rid < 0) begin
                    west_net[rid].flit_out = '0;
                    west_net[rid].req_out = 0;
                    west_net[rid].ack_in = 0;
                end
            end
        end
    end

    // Connect cores to local ports (pack/unpack flits)
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c++) begin : gen_core_connect
            int rid = CORE_ROUTER_MAP[c];
            // Pack core to flit (to local in)
            always_comb begin
                generic_flit_t core_flit;
                core_flit.addr = core_mem_if[c].addr;
                core_flit.is_read = core_mem_if[c].read_req;
                core_flit.is_wide = core_mem_if[c].data_wide_valid && is_srf_mode;
                core_flit.transfer_type = is_srf_mode ? 1 : 0;  // Example: 1=block; extend for strided/indirect
                core_flit.payload_size = core_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;  // Bytes
                core_flit.data = core_flit.is_wide ? core_mem_if[c].data_wide[FLIT_SIZE-1:0] : core_mem_if[c].store_data[FLIT_SIZE-1:0];
                core_flit.last_flit = core_flit.payload_size <= FLIT_SIZE / 8;  // Single if small
                core_flit.ipriority = core_flit.is_wide ? 1 : 0;
                core_flit.src_core = c;

                local_net[rid].flit_in = core_flit;
                local_net[rid].req_in = core_mem_if[c].read_req || core_mem_if[c].write_req;
                core_mem_if[c].ack = local_net[rid].ack_out;
            end

            // Unpack from local out to core (response)
            always_comb begin
                if (local_net[rid].req_out) begin
                    generic_flit_t resp_flit = local_net[rid].flit_out;
                    if (resp_flit.src_core == c) begin  // Route back to src core
                        core_mem_if[c].data_wide = resp_flit.is_wide ? resp_flit.data : '0;  // Unpack
                        local_net[rid].ack_in = 1;
                    end
                end
            end
        end
    endgenerate

    // Connect tiles to local ports (unpack/pack flits)
    genvar t;
    generate
        for (t = 0; t < NUM_TILES; t++) begin : gen_tile_connect
            int rid = TILE_ROUTER_MAP[t];
            // Unpack from local out to tile
            always_comb begin
                if (local_net[rid].req_out) begin
                    generic_flit_t req_flit = local_net[rid].flit_out;
                    tile_mem_if[t].addr = req_flit.addr;
                    tile_mem_if[t].read_req = req_flit.is_read;
                    tile_mem_if[t].write_req = !req_flit.is_read;
                    tile_mem_if[t].data_wide = req_flit.is_wide ? req_flit.data : '0;
                    tile_mem_if[t].config_srf = is_srf_mode;

                    local_net[rid].ack_in = tile_mem_if[t].ack;
                end
            end

            // Pack tile response to local in (for return path)
            always_comb begin
                generic_flit_t resp_flit;
                resp_flit.addr = tile_mem_if[t].addr;  // Return to src
                resp_flit.is_read = 0;  // Response
                resp_flit.is_wide = tile_mem_if[t].data_wide_valid && is_srf_mode;
                resp_flit.transfer_type = 0;
                resp_flit.payload_size = resp_flit.is_wide ? WIDE_WIDTH / 8 : FLIT_SIZE / 8;
                resp_flit.data = tile_mem_if[t].data_wide[FLIT_SIZE-1:0];
                resp_flit.last_flit = 1;
                resp_flit.ipriority = 0;
                resp_flit.src_core = 0;  // Set from req (tracked in tile; simplified dummy)

                local_net[rid].flit_in = resp_flit;
                local_net[rid].req_in = tile_mem_if[t].ack && tile_mem_if[t].read_req;  // Response on read
                // Tile ack already handled above
            end
        end
    endgenerate

    // External mem connect (to bottom-right router)
    localparam int EXT_ROUTER_ID = (ROUTER_ROWS-1) * ROUTER_COLS + (ROUTER_COLS-1);
    int ext_rid = EXT_ROUTER_ID;

    // Pack ext to flit (to local in)
    always_comb begin
        generic_flit_t ext_flit;
        ext_flit.addr = ext_mem_if.addr;
        ext_flit.is_read = ext_mem_if.read_req;
        ext_flit.is_wide = 0;  // External not wide
        ext_flit.transfer_type = 0;
        ext_flit.payload_size = FLIT_SIZE / 8;
        ext_flit.data = ext_mem_if.store_data[FLIT_SIZE-1:0];
        ext_flit.last_flit = 1;
        ext_flit.ipriority = 0;
        ext_flit.src_core = 0;  // Dummy

        local_net[ext_rid].flit_in = ext_flit;
        local_net[ext_rid].req_in = ext_mem_if.read_req || ext_mem_if.write_req;
        ext_mem_if.ack = local_net[ext_rid].ack_out;
    end

    // Unpack from local out to ext (response)
    always_comb begin
        if (local_net[ext_rid].req_out) begin
            generic_flit_t ext_resp = local_net[ext_rid].flit_out;
            ext_mem_if.data_wide = ext_resp.data;  // Unpack
            local_net[ext_rid].ack_in = 1;
        end
    end

endmodule
