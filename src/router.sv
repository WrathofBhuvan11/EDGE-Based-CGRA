// Router module: 5-port XY with RR arb, wormhole, buffers
    module router #(
        parameter ROUTER_ID = 0
    ) (
        input logic clk,
        input logic rst_n,
        input logic is_srf_mode,
        router_if.north north_if,
        router_if.south south_if,
        router_if.east east_if,
        router_if.west west_if,
        router_if.local local_if
    );

        localparam NUM_PORTS = 5;
        localparam NORTH = 0, SOUTH = 1, EAST = 2, WEST = 3, LOCAL = 4;
        localparam CURR_ROW = ROUTER_ID / `ROUTER_COLS;  // Assume global COLS
        localparam CURR_COL = ROUTER_ID % `ROUTER_COLS;

        // Buffers per input
        flit_t buf [NUM_PORTS-1:0] [BUFFER_DEPTH-1:0];
        logic [$clog2(BUFFER_DEPTH):0] head [NUM_PORTS-1:0], tail [NUM_PORTS-1:0];
        logic full [NUM_PORTS-1:0], empty [NUM_PORTS-1:0];

        // Req/grant matrix (out x in)
        logic [NUM_PORTS-1:0] req_matrix [NUM_PORTS-1:0];
        logic [NUM_PORTS-1:0] grant_matrix [NUM_PORTS-1:0];

        // RR pointers per output
        logic [NUM_PORTS-1:0] rr_ptr [NUM_PORTS-1:0];

        // Reset
        always_ff @(posedge clk or negedge rst_n) if (!rst_n) begin
            for (int p=0; p<NUM_PORTS; p++) begin
                head[p] <= 0; tail[p] <= 0; full[p] <= 0; empty[p] <= 1; rr_ptr[p] <= 0;
            end
        end

        // Buffer push/pop (per port; generalized)
        genvar p;
        generate
            for (p = 0; p < NUM_PORTS; p++) begin : gen_ports
                logic req_in_port = (p==NORTH) ? north_if.req_in : (p==SOUTH) ? south_if.req_in : (p==EAST) ? east_if.req_in : (p==WEST) ? west_if.req_in : local_if.req_in;
                flit_t flit_in_port = (p==NORTH) ? north_if.flit_in : (p==SOUTH) ? south_if.flit_in : (p==EAST) ? east_if.flit_in : (p==WEST) ? west_if.flit_in : local_if.flit_in;
                logic ack_out_port; assign (p==NORTH) ? north_if.ack_out = ack_out_port : (p==SOUTH) ? south_if.ack_out = ack_out_port : (p==EAST) ? east_if.ack_out = ack_out_port : 
                                                                                                       (p==WEST) ? west_if.ack_out = ack_out_port : local_if.ack_out = ack_out_port;

                always_ff @(posedge clk) begin
                    // Push
                    if (req_in_port && !full[p]) begin
                        buf[p][tail[p]] = flit_in_port;
                        tail[p] <= (tail[p] + 1) % BUFFER_DEPTH;
                        empty[p] <= 0;
                        full[p] <= ((tail[p] + 1) % BUFFER_DEPTH == head[p]);
                        ack_out_port <= 1;
                    end else ack_out_port <= 0;
                    // Pop if granted to any out
                    if (|grant_matrix[p] && !empty[p]) begin
                        head[p] <= (head[p] + 1) % BUFFER_DEPTH;
                        full[p] <= 0;
                        empty[p] <= ((head[p] + 1) % BUFFER_DEPTH == tail[p]);
                    end
                end
            end
        endgenerate

        // Req matrix
        always_comb begin
            for (int out=0; out<NUM_PORTS; out++) for (int in=0; in<NUM_PORTS; in++) req_matrix[out][in] = 0;
            for (int in=0; in<NUM_PORTS; in++) if (!empty[in]) begin
                int out_port = get_output_port(buf[in][head[in]].addr);
                req_matrix[out_port][in] = 1;
            end
        end

        // Function to get output port (XY routing)
        function logic [2:0] get_output_port(logic [ADDR_WIDTH-1:0] dest_addr);
            int dest_tile = dest_addr[4:0] % NUM_TILES;  // Simplified tile ID from addr
            int dest_row = dest_tile / ROUTER_COLS;
            int dest_col = dest_tile % ROUTER_COLS;
            if (dest_col > CURR_COL) return EAST;
            else if (dest_col < CURR_COL) return WEST;
            else if (dest_row > CURR_ROW) return SOUTH;
            else if (dest_row < CURR_ROW) return NORTH;
            else return LOCAL;
        endfunction

        // Arbitration and grant
        always_ff @(posedge clk) begin
            for (int out=0; out<NUM_PORTS; out++) begin
                grant_matrix[out] = 0;
                logic granted = 0;
                for (int offset=0; offset<NUM_PORTS; offset++) begin
                    int in = (rr_ptr[out] + offset) % NUM_PORTS;
                    if (req_matrix[out][in] && !granted) begin
                        // Priority check: Grant if high pri or std RR
                        if (buf[in][head[in]].priority > 0 || !high_pri_req) begin
                            grant_matrix[out][in] = 1;
                            granted = 1;
                            rr_ptr[out] <= (in + 1) % NUM_PORTS;
                        end
                    end
                end
            end
        end

        // Forwarding: Mux flit_out per output from granted input
        always_comb begin
            for (int out=0; out<NUM_PORTS; out++) begin
                flit_t sel_flit = '0;
                logic has_grant = 0;
                for (int in=0; in<NUM_PORTS; in++) if (grant_matrix[out][in]) begin
                    sel_flit = buf[in][head[in]];
                    has_grant = 1;
                end
                // Assign to output port
                case (out)
                    NORTH: begin north_if.flit_out = sel_flit; north_if.req_out = has_grant; end
                    SOUTH: begin south_if.flit_out = sel_flit; south_if.req_out = has_grant; end
                    EAST: begin east_if.flit_out = sel_flit; east_if.req_out = has_grant; end
                    WEST: begin west_if.flit_out = sel_flit; west_if.req_out = has_grant; end
                    LOCAL: begin local_if.flit_out = sel_flit; local_if.req_out = has_grant; end
                endcase
            end
        end

        // Ack_in from downstream (backpressure; assigned in mesh connect always_comb above)

    endmodule