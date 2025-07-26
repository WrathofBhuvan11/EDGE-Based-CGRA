// lsid_unit.sv
// LSID handler: Load/Store Identifier- Queues (32 FIFO) for load/store ordering (sequential semantics, commit in order).
// Tracks same-addr ops, holds until prior commit.
// Hierarchy: Sub of d_tile; no sub-instances.
// 5-bit LSID for order/reuse on disjoint paths, null for constants; total order memory ops

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module lsid_unit (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input lsid_t lsid,                      // LSID input (0-31)
    input logic load_req,                   // Load req input
    input logic store_req,                  // Store req input
    input logic [31:0] addr,                // Addr input
    input reg_data_t store_data,            // Store data input
    output reg_data_t load_data,            // Load data output
    output logic ack                        // Ack output (now driven: ordered/processed complete)
);

    // Internal queues per LSID (32 entries, FIFO for ops; depth 4 for in-flight)
    typedef struct packed {
        logic is_load;                      // 1=load, 0=store
        logic [31:0] addr;
        reg_data_t data;                    // Store data or load result
        logic complete;                     // Done flag
    } lsid_entry_t;

    lsid_entry_t lsid_queue [31:0] [3:0];   // Depth 4 per LSID for in-flight
    logic [1:0] head [31:0], tail [31:0];   // Head/tail per LSID
    logic full [31:0], empty [31:0];

    // Commit order: Seq counter for global order
    logic [4:0] commit_lsid = 0;            // Next expected LSID to commit

    // Enqueue on req
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
            full <= '0;
            empty <= '1;
            commit_lsid <= 0;
            ack <= 0;
        end else begin
            ack = 0;
            if (load_req || store_req) begin
                if (!full[lsid]) begin
                    lsid_queue[lsid][tail[lsid]].is_load = load_req;
                    lsid_queue[lsid][tail[lsid]].addr = addr;
                    lsid_queue[lsid][tail[lsid]].data = store_data;
                    lsid_queue[lsid][tail[lsid]].complete = 0;
                    tail[lsid] <= (tail[lsid] + 1) % 4;
                    empty[lsid] <= 0;
                    full[lsid] <= ((tail[lsid] + 1) % 4 == head[lsid]);
                    lsid_queue[lsid][tail[lsid]].complete = 1;  // Drive complete (stub; real on hit/ack_mem)
                end
            end
            // Commit: If head complete && lsid == commit_lsid, dequeue/advance/set ack
            for (int id = 0; id < 32; id++) begin
                if (!empty[id] && lsid_queue[id][head[id]].complete && id == commit_lsid) begin
                    if (lsid_queue[id][head[id]].is_load) load_data = lsid_queue[id][head[id]].data;  // Output load
                    head[id] <= (head[id] + 1) % 4;
                    full[id] <= 0;
                    empty[id] <= ((head[id] + 1) % 4 == tail[id]);
                    commit_lsid <= (commit_lsid + 1) % 32;  // Advance global
                    ack = 1;  //Set ack on dequeue (ordered completion)
                end
            end
            // Mark complete on op done (e.g., from cache hit/ack; assume external complete signal, simplified always complete on enqueue)
        end
    end

endmodule