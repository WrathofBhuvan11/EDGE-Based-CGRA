// switching_network.sv
// Lightweight operand routing mesh: Routes operands between E-nodes using targets (N/W slots 0/1/p, X/Y/Z offsets).
// 2D mesh with routers (XY routing, simple flits, RR arbitration; 1-cycle hops for low-latency dataflow).
// Unchanged across morphs; supports up to 2 targets/instr.
// Hierarchy: Standalone; router array for E-node interconnect (no sub-instances beyond routers).
// References: Polymorphous paper (Sec. 2.1: Routed network in ALU array, 1-cycle hops, X/Y/Z relative offsets; Fig. 2c node with res stations/router), compiler paper (Sec. 2: Lightweight switching for operand forwarding), TASL manual (Sec. 4.5: Targets N[target,slot] or W[queue]; up to 2 targets, p for pred).
// Design: Adapted router from mem net (simplified flit: operand/dest_instr/slot; XY to node from instr_num).
`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module switching_network #(
    parameter GRID_ROWS = `GRID_ROWS,       // E-grid rows (4)
    parameter GRID_COLS = `GRID_COLS        // E-grid cols (4)
) (
    input clk,                              // Network clock (synchronous with core)
    input rst_n,                            // Active-low reset (reset all routers/buffers)
    input morph_config_t morph_config,      // Morph configuration (unchanged, but for future extensions like priority adjustments)
    // Inputs to network (from E-Tiles; sender path)
    input operand_t in_operand [GRID_ROWS*GRID_COLS-1:0],  // Operand array input (data/valid/source_instr from E-nodes)
    input instr_num_t in_dest_instr [GRID_ROWS*GRID_COLS-1:0],  // Dest instr array input (target instruction number)
    input logic [1:0] in_dest_slot [GRID_ROWS*GRID_COLS-1:0],   // Dest slot array input (0=left,1=right,2=p)
    input logic in_req [GRID_ROWS*GRID_COLS-1:0],               // Req array input (request to route)
    input logic in_ack [GRID_ROWS*GRID_COLS-1:0],               // Ack array input (from E-Tiles to Network)

    // Outputs from network (to E-Tiles; receiver path)
    output operand_t out_operand [GRID_ROWS*GRID_COLS-1:0],     // Operand array output
    output instr_num_t out_dest_instr [GRID_ROWS*GRID_COLS-1:0],// Dest instr array output
    output logic [1:0] out_dest_slot [GRID_ROWS*GRID_COLS-1:0], // Dest slot array output
    output logic out_req [GRID_ROWS*GRID_COLS-1:0],             // Req array output
    output logic out_ack [GRID_ROWS*GRID_COLS-1:0]              // Ack array output (from Network to E-Tiles)
);

    localparam TOTAL_ROUTERS = GRID_ROWS * GRID_COLS;
    // Set FLIT_TYPE to 0 for operand net (from generalized router)
    localparam FLIT_TYPE = 0;               // 0=operand (dest_instr-based)

    // Router array: 2D mesh interfaces (per direction)
    // 1D flattened interfaces (per direction)Patch fix to address verilator 2D interface handling issue
    router_if north_net [TOTAL_ROUTERS-1:0] ();
    router_if south_net [TOTAL_ROUTERS-1:0] ();
    router_if east_net [TOTAL_ROUTERS-1:0] ();
    router_if west_net [TOTAL_ROUTERS-1:0] ();
    router_if local_net [TOTAL_ROUTERS-1:0] ();

    // Instantiate routers: Generate 2D array with FLIT_TYPE=0
    genvar r_row, r_col;
    generate
        for (r_row = 0; r_row < GRID_ROWS; r_row++) begin : gen_router_rows
            for (r_col = 0; r_col < GRID_COLS; r_col++) begin : gen_router_cols
                localparam int RID = r_row * GRID_COLS + r_col;
                router #(
                    .ROUTER_ID(RID),
                    .ROUTER_COLS(GRID_COLS),
                    .FLIT_TYPE(FLIT_TYPE),          // 0 for operand (dest_instr-based)
                    .BUFFER_DEPTH(4)
                ) router_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .is_srf_mode(1'b0),     // Unused in operand net
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
        for (int rr = 0; rr < GRID_ROWS; rr++) begin
            for (int rc = 0; rc < GRID_COLS; rc++) begin
                int rid = rr * GRID_COLS + rc;
                int north_rid = (rr > 0) ? (rr-1) * GRID_COLS + rc : -1;
                int south_rid = (rr < GRID_ROWS-1) ? (rr+1) * GRID_COLS + rc : -1;
                int east_rid = (rc < GRID_COLS-1) ? rr * GRID_COLS + (rc+1) : -1;
                int west_rid = (rc > 0) ? rr * GRID_COLS + (rc-1) : -1;

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

    // Connect E-nodes to local ports (operand signals to local_net; FLIT_TYPE=0)
    genvar row, col;
    generate
        for (row = 0; row < GRID_ROWS; row++) begin : gen_connect_rows
            for (col = 0; col < GRID_COLS; col++) begin : gen_connect_cols
                localparam int RID = row * GRID_COLS + col;
                int rid = row * GRID_COLS + col;
                // From E-node to router local in (sender signals; pack to generalised flit, unused mem fields 0)
                always_comb begin
                    generic_flit_t op_flit;
                    op_flit.operand = in_operand[RID];
                    op_flit.dest_instr = in_dest_instr[RID];
                    op_flit.dest_slot = in_dest_slot[RID];
                    op_flit.ipriority = 0;  // Std for operand net
                    op_flit.addr = '0;     // Unused in operand (FLIT_TYPE=0)
                    op_flit.is_read = 0;
                    op_flit.is_wide = 0;
                    op_flit.transfer_type = 0;
                    op_flit.payload_size = 0;
                    op_flit.data = '0;
                    op_flit.last_flit = 1; // Single-flit
                    op_flit.src_core = 0;

                    local_net[rid].flit_in = op_flit;
                    local_net[rid].req_in = in_req[RID];
                    out_ack[RID] = local_net[rid].ack_out;
                end

                // From router local out to E-node (receiver signals; unpack from generalised)
                always_comb begin
                    generic_flit_t resp_flit = local_net[rid].flit_out;
                    out_operand[RID] = resp_flit.operand;
                    out_dest_instr[RID] = resp_flit.dest_instr;
                    out_dest_slot[RID] = resp_flit.dest_slot;
                    out_req[RID] = local_net[rid].req_out;
                    local_net[rid].ack_in = in_ack[RID];  // Backpressure from E
                end
            end
        end
    endgenerate

endmodule
