// r_tile.sv
// Register bank tile: One of 4 banks (32 regs each, total 128 G[0-127]); handles read/write queues (R/W[0-31] per block), alignment checks (queue mod 8 == reg mod 4).
// Buffers for in-flight (64 rd/wr per bank for 8 blocks x8/block); persistent across morphs (no reconfiguration).
// Hierarchy: Standalone in core; no sub-instances.
// - Banked reg file 4x32=128, queues for block reads/writes,
// - rd/wr/block, 8/bank restriction for buffering,
// - G[0-127] persistent, R/W[0-31] queues, alignment mod 4 for banks

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module r_tile #(
    parameter BANK_ID = 0,                  // Bank ID (0-3)
    parameter REGS_PER_BANK = `REGS_PER_BANK,  // 32 regs/bank
    parameter QUEUE_DEPTH = 32,             // R/W queue entries/block
    parameter INFLIGHT_BLOCKS = `MAX_INFLIGHT_BLOCKS  // 8 blocks
) (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input morph_config_t morph_config,      // Morph configuration 
    input logic read_req,                   // Read request input 
    input logic write_req,                  // Write request input
    input logic [6:0] reg_id,               // Reg ID input (G[0-127])
    input logic [4:0] queue_id,             // Queue ID input (R/W[0-31])
    input reg_data_t write_data,            // Write data input
    output reg_data_t read_data,            // Read data output
    output logic ack,                       // Ack output
    output logic alignment_err              // Alignment error output (mod 4)
);

    // Internal storage: RAM for 32 regs/bank (persistent G regs slice: e.g., bank0 G[0,4,8,...])
    reg_data_t regs [REGS_PER_BANK-1:0];

    // Queues: Simplified buffers for rd/wr (per block x in-flight; but model as direct for sim - extend for multi-block)
    reg_data_t rd_queue [QUEUE_DEPTH-1:0];  // Read queue (R[0-31])
    reg_data_t wr_queue [QUEUE_DEPTH-1:0];  // Write queue (W[0-31])
    logic rd_valid [QUEUE_DEPTH-1:0];       // Valid flags for queue entries
    logic wr_valid [QUEUE_DEPTH-1:0];

    // Alignment check: queue mod 8 == reg mod 4 (bank interleaving)
    always_comb begin
        alignment_err = (read_req || write_req) && ((queue_id % 8) != (reg_id % 4));
    end

    // Read logic: From regs to rd_queue or direct output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            regs <= '0;             
            rd_queue <= '0;
            wr_queue <= '0;
            rd_valid <= '0;
            wr_valid <= '0;
            read_data <= '0;
            ack <= 0;
        end else begin
            ack = 0;
            if (alignment_err) begin
                ack = 1;  // Ack but err flagged
            end else if (read_req) begin
                // Read from regs (bank-local ID: reg_id / 4 or mod)
                int local_reg_id = (reg_id / 4) % REGS_PER_BANK;  // Interleaved: G[id] in bank (id % 4)
                read_data = regs[local_reg_id];
                rd_queue[queue_id] = read_data;  // Buffer in queue for block
                rd_valid[queue_id] = 1;
                ack = 1;
            end else if (write_req) begin
                int local_reg_id = (reg_id / 4) % REGS_PER_BANK;
                regs[local_reg_id] = write_data;
                wr_queue[queue_id] = write_data;  // Buffer if needed; but writes direct
                wr_valid[queue_id] = 1;
                ack = 1;
            end
        end
    end

    // Morph handling: Regs persistent, no action needed (morph_config unused)

endmodule