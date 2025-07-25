// Router module: 5-port XY with RR arb, wormhole, bufferfers
`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module router #(
    parameter ROUTER_ID = 0,
    parameter ROUTER_COLS = 4,              // Cols for XY
    parameter FLIT_TYPE = 0,                // 0=operand, 1=mem
    parameter BUFFER_DEPTH = 4
) (
    input clk,
    input rst_n,
    input logic is_srf_mode,                // For mem wide pri (if FLIT_TYPE=1)
    router_if.north north_if,
    router_if.south south_if,
    router_if.east east_if,
    router_if.west west_if,
    router_if.iolocal local_if
);
    
    localparam CURR_ROW = ROUTER_ID / ROUTER_COLS;
    localparam CURR_COL = ROUTER_ID % ROUTER_COLS;
    localparam NUM_TILES = `NUM_L2_TILES;

    // Buffers
    generic_flit_t buffer [NUM_PORTS-1:0] [BUFFER_DEPTH-1:0];
    logic [$clog2(BUFFER_DEPTH+1)-1:0] head [NUM_PORTS-1:0], tail [NUM_PORTS-1:0];
    logic full [NUM_PORTS-1:0], empty [NUM_PORTS-1:0];

    // Req/grant
    logic [NUM_PORTS-1:0] req_matrix [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0] grant_matrix [NUM_PORTS-1:0];

    // RR ptr
    logic [NUM_PORTS-1:0] rr_ptr [NUM_PORTS-1:0];

    logic granted;

    // High pri (combo; conditional on FLIT_TYPE=1 wide)
    logic high_pri_req;
    always_comb begin
        high_pri_req = 0;
        for (int p = 0; p < NUM_PORTS; p++) if (!empty[p] && buffer[p][head[p]].ipriority > 0) high_pri_req = 1;
    end

    // Reset
    always_ff @(posedge clk or negedge rst_n) 
    if (!rst_n) for (int p=0; p<NUM_PORTS; p++) begin
        head[p] <= 0; tail[p] <= 0; full[p] <= 0; empty[p] <= 1; rr_ptr[p] <= 0;
    end

    // Buffer push/pop (gen per port)
    genvar p;
    generate for (p = 0; p < NUM_PORTS; p++) begin : gen_ports
        always_ff @(posedge clk) begin
            // Push
            generic_flit_t flit_in_port = (p==NORTH) ? north_if.flit_in : (p==SOUTH) ? south_if.flit_in : (p==EAST) ? east_if.flit_in : (p==WEST) ? west_if.flit_in : local_if.flit_in;
            logic req_in_port = (p==NORTH) ? north_if.req_in : (p==SOUTH) ? south_if.req_in : (p==EAST) ? east_if.req_in : (p==WEST) ? west_if.req_in : local_if.req_in;
            logic ack_out_port;
            if (req_in_port && !full[p]) begin
                buffer[p][tail[p]] <= flit_in_port;
                tail[p] <= (tail[p] + 1) % BUFFER_DEPTH;
                empty[p] <= 0;
                full[p] <= ((tail[p] + 1) % BUFFER_DEPTH == head[p]);
                ack_out_port = 1;
            end else ack_out_port = 0;

            // Assign ack_out (ff for registered; fix-combo mux separate if latch issue)
            case (p)
                NORTH: north_if.ack_out <= ack_out_port;
                SOUTH: south_if.ack_out <= ack_out_port;
                EAST: east_if.ack_out <= ack_out_port;
                WEST: west_if.ack_out <= ack_out_port;
                LOCAL: local_if.ack_out <= ack_out_port;
            endcase

            // Pop if granted
            if (|grant_matrix[p] && !empty[p]) begin
                head[p] <= (head[p] + 1) % BUFFER_DEPTH;
                full[p] <= 0;
                empty[p] <= ((head[p] + 1) % BUFFER_DEPTH == tail[p]);
            end
        end
    end endgenerate

    // Req matrix
    always_comb begin
        for (int out=0; out<NUM_PORTS; out++) for (int in=0; in<NUM_PORTS; in++) req_matrix[out][in] = 0;
        for (int in=0; in<NUM_PORTS; in++) if (!empty[in]) begin
            //int out_port = get_output_port(buffer[in][head[in]]);
            req_matrix[get_output_port(buffer[in][head[in]])][in] = 1;
        end
    end

    // Get output port (conditional on FLIT_TYPE: dest_instr for operand, addr for mem)
    function logic [2:0] get_output_port(generic_flit_t flit);
        logic [ADDR_WIDTH-1:0] dest_val;  // General dest (instr or addr)
        logic [$clog2(GRID_COLS)-1:0] cols_param = GRID_COLS;  // Local from param
        logic [$clog2(NUM_TILES)-1:0] tiles_param = NUM_TILES;  // Local
        if (FLIT_TYPE == 0) begin  // Operand: dest_instr to row/col
            dest_val = $unsigned(flit.dest_instr);  // Cast unsigned
            //int dest_row = dest_val / cols_param;
            //int dest_col = dest_val % cols_param;
            if ((dest_val % cols_param) > CURR_COL) return EAST;
            if ((dest_val % cols_param) < CURR_COL) return WEST;
            if ((dest_val / cols_param) > CURR_ROW) return SOUTH;
            if ((dest_val / cols_param) < CURR_ROW) return NORTH;
            return LOCAL;
        end else begin  // Mem: addr to tile row/col (ID to coord)
            logic [$clog2(ADDR_WIDTH)-1:0] addr_hash = flit.addr[4:0];  // Low 5 bits
            int dest_tile = addr_hash % tiles_param;
            //int dest_row = dest_tile / ROUTER_COLS;
            //int dest_col = dest_tile % ROUTER_COLS;
            if ((dest_tile % ROUTER_COLS) > CURR_COL) return EAST;
            if ((dest_tile % ROUTER_COLS) < CURR_COL) return WEST;
            if ((dest_tile / ROUTER_COLS) > CURR_ROW) return SOUTH;
            if ((dest_tile / ROUTER_COLS) < CURR_ROW) return NORTH;
            return LOCAL;
        end
    endfunction

    // Arb/grant (ff)
    always_ff @(posedge clk) for (int out=0; out<NUM_PORTS; out++) begin
        grant_matrix[out] = 0;
        granted = 0;
        for (int offset=0; offset<NUM_PORTS; offset++) begin
            int in = (rr_ptr[out] + offset) % NUM_PORTS;
            if (req_matrix[out][in] && !granted) begin
                if (buffer[in][head[in]].ipriority > 0 || !high_pri_req) begin
                    grant_matrix[out][in] = 1;
                    granted = 1;
                    rr_ptr[out] <= (in + 1) % NUM_PORTS;
                end
            end
        end
    end

    // Forward mux (comb)
    always_comb for (int out=0; out<NUM_PORTS; out++) begin
        generic_flit_t sel_flit = '0;
        logic has_grant = 0;
        for (int in=0; in<NUM_PORTS; in++) if (grant_matrix[out][in]) begin
            sel_flit = buffer[in][head[in]];
            has_grant = 1;
        end
        case (out)
            NORTH: {north_if.flit_out, north_if.req_out} = {sel_flit, has_grant};
            SOUTH: {south_if.flit_out, south_if.req_out} = {sel_flit, has_grant};
            EAST: {east_if.flit_out, east_if.req_out} = {sel_flit, has_grant};
            WEST: {west_if.flit_out, west_if.req_out} = {sel_flit, has_grant};
            LOCAL: {local_if.flit_out, local_if.req_out} = {sel_flit, has_grant};
        endcase
    end

endmodule
