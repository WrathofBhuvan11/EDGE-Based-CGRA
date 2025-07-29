// e_tile.sv
// Execution node tile: Individual grid spot with ALU/FP for ops (G/I/C classes with %bit), res station (frames 8-16) for dataflow matching (3 slots: left/right/pred), predicate logic (_t/_f true).
// Fires instr when ready/pred true, routes output to targets via operand signals (up to 2, slots 0/1/p or W queue).
// Hierarchy: Contains alu_fp_unit (ops/%bit), reservation_station (matching/slots; with predicate_handler sub).
// E-node ALU/FP/res stations/router, 1-cycle hops; morph partitioning/revitalization, E-tiles/res station for dataflow fire,
// G/I/C ops with %bit, pred _t/_f/p slot, targets up to 2 N/W).

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module e_tile #(
    parameter ROW_ID = 0,                   // Node row ID (for routing/X offset)
    parameter COL_ID = 0,                   // Node col ID (Y offset)
    parameter FRAMES = `FRAMES_PER_NODE     // Frames/node (8 for 128 total in 4x4)
) (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input morph_config_t morph_config,      // Morph configuration (frame partitioning/revitalization)
    // Operand receiver signals (from network; dataflow input)
    input operand_t operand_in,             // Operand input (data/valid/source_instr)
    input instr_num_t dest_instr_in,        // Dest instr input (target num for routing)
    input logic [1:0] dest_slot_in,         // Dest slot input (0=left,1=right,2=p)
    input logic req_in,                     // Req input (operand ready to receive)
    output logic ack_out,                   // Ack output (received/processed)
    // Reg access if tile port (to R-bank; for R/W queues)
    output logic read_req,                  // Read req output (TASL read to queue)
    output logic write_req,                 // Write req output (to W queue)
    output logic [6:0] reg_id,              // Reg ID output (G[0-127])
    output logic [4:0] queue_id,            // Queue ID output (R/W[0-31])
    output reg_data_t write_data,           // Write data output
    input reg_data_t read_data,             // Read data input
    input logic ack_reg,                    // Ack input from bank
    input logic alignment_err,              // Alignment err input (mod 4)
    // Mem access if tile port (to D-tile; for L/S ops)
    output logic load_req,                  // Load req output (L class)
    output logic store_req,                 // Store req output (S class)
    output lsid_t lsid,                     // LSID output
    output logic [31:0] addr,               // Addr output
    output reg_data_t store_data,           // Store data output
    input reg_data_t load_data,             // Load data input
    input logic hit,                        // Hit input
    input logic ack_mem,                    // Ack input from D
    // Instr input from I-tile (decoded class/opcode/target etc.)
    input instr_t instr_in,                 // Instr input (classes G/I/L/S/B/C)
    // Branch outputs to G-tile (for speculation/next_addr)
    output logic branch_taken,              // Branch outcome output (B class cond true)
    output logic [4:0] exit_id,             // EXIT_ID output (for multiple exits)
    // Operand sender signals (to network; for forwarding results)
    output operand_t operand_out,           // Operand output for sending
    output instr_num_t dest_instr_out,      // Dest instr output
    output logic [1:0] dest_slot_out,       // Dest slot output
    output logic req_out,                   // Req output for sending
    input logic ack_in,                     // Ack input from network
    input logic revitalize_broadcast        // Revitalization input (S-morph loop reset signal; broadcast from G/morph)
);

    // Internal signals
    logic revitalize_internal;              // Internal revitalize from morph (for S-morph reset)
    logic fire_ready;                       // Instr ready to fire from res_station
    logic pred_valid;                       // Predicate outcome from handler (_t/_f true)
    reg_data_t alu_result;                  // Result from ALU (to route/mem/reg)
    logic alu_valid;                        // ALU output valid
    logic [1:0] pending_ack;                // Flags for target acks (bit0 tgt0, bit1 tgt1; wait if 0)
    operand_t [2:0] res_operands;           // Operands from res_station (left/right/pred; fix undef dotted ref)

    assign revitalize_internal = revitalize_broadcast;

    // Instantiate reservation_station (buffers frames, matches operands/pred)
    reservation_station #(
        .FRAMES(FRAMES),
        .NODE_ID(ROW_ID * GRID_COLS + COL_ID)  // Pass node ID for match (row*COLS + col)
    ) res_station_inst (
        .clk(clk),
        .rst_n(rst_n),
        .morph_config(morph_config),        // For partitioning/revitalization (reset frames, keep constants in S-morph)
        .instr_in(instr_in),                // Instr from I-tile (class/opcode/targets etc.)
        .operand_in(operand_in),            // Operand from network
        .dest_instr_in(dest_instr_in),      // input for dest instr match
        .dest_slot_in(dest_slot_in),        // input for slot case
        .req_in(req_in),                    // Req from network
        .ack_out(ack_out),                  // Ack to network
        .fire_ready(fire_ready),            // Output: Ready to fire to ALU
        .revitalize(revitalize_internal),   // Input: Revitalization signal (S-morph reset)
        .operands(res_operands)             // Operands output from res_station (left/right/pred; fix undef ref)
    );

    // Instantiate predicate_handler (sub of res_station; _t/_f check on pred_operand)
    predicate_handler pred_handler_inst (
        .predicate_en(instr_in.predicate_en), // Enable if _t/_f
        .predicate_true(instr_in.predicate_true), // 1=_t, 0=_f
        .pred_operand(res_operands[2]),     // Pred operand from res_station (fix undef by using res_operands[2] for pred)
        .pred_valid(pred_valid)             // True if condition met
    );

    // Instantiate alu_fp_unit (ops for G/I/C; %bit extract)
    alu_fp_unit alu_fp_inst (
        .clk(clk),
        .rst_n(rst_n),
        .opcode(instr_in.opcode),               // Opcode (e.g., OP_ADD/OP_TEQ)
        .isa_class(instr_in.isa_class),         // Class (G/I/C)
        .operands({res_operands[0], res_operands[1]}),   // Left/right from res_station (fix undef with res_operands[0:1])
        .imm_value(instr_in.imm_value),         // Imm for I/C
        .bit_extract(instr_in.bit_extract),     // %bit for C
        .fire(fire_ready && pred_valid),        // Fire if ready and pred true
        .result(alu_result),                    // Output result
        .valid_out(alu_valid)                   // Valid output flag
    );

    // Routing logic: On ALU output, send to operand sender signals for targets (up to 2)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
	    pending_ack <= '0;
            operand_out <= '0;
            dest_instr_out <= '0;
            dest_slot_out <= '0;
            req_out <= 0;
            read_req <= 0; // Drive undriven output
            write_req <= 0;
            reg_id <= '0;
            queue_id <= '0;
            write_data <= '0;
        end else begin
            if (alu_valid) begin
                // For each target (from instr_in.targets[0:1])
                for (int tgt = 0; tgt < 2; tgt++) begin
                    if (instr_in.targets[tgt].valid) begin
                        if (instr_in.targets[tgt].is_write_queue) begin
                            // To W queue via reg_if (write_req to bank)
                            reg_id <= instr_in.targets[tgt].target_instr;  // W as reg_id (G target)
                            queue_id <= instr_in.targets[tgt].target_instr[4:0];  // Lower bits for queue [0-31]
                            write_req <= 1;                        // Set write req
                            write_data <= alu_result;              // Result to write
                            // Wait for ack_reg (simple retry if !ack; assume non-blocking, flag if pending)
                            if (ack_reg) pending_ack[tgt] <= 0;
                            else pending_ack[tgt] <= 1;  // Set pending, retry next cycle (add state if blocking needed)
                        end else begin
                            // To N[target,slot] via operand_out (but since mesh, route via switching)
                            // Pack and send to sender signals (output to network)
                            operand_out.data <= alu_result;  // Result as operand data (operand_t.data)
                            operand_out.valid <= 1;             // Valid
                            operand_out.source_instr <= COL_ID * GRID_ROWS + ROW_ID;  // Source node ID (for debug)
                            dest_instr_out <= instr_in.targets[tgt].target_instr;  // Target num
                            dest_slot_out <= instr_in.targets[tgt].slot;    // Slot (0/1/p)
                            req_out <= 1;               // Request route
                            // Wait for ack_in (simple retry)
                            if (ack_in) pending_ack[tgt] <= 0;
                            else pending_ack[tgt] <= 1;
                        end
                    end
                end
            end
            // Handle reg read 
            read_req <= (instr_in.opcode == `OP_READ_REG && fire_ready && pred_valid) ? 1 : 0;  // Drive based on instr
            if (read_req) begin
                reg_id <= instr_in.reg_id;  // Set from instr
                queue_id <= instr_in.reg_id[4:0];
                if (read_data != '0) operand_out.data <= read_data;  // integrate to res_station
            end
            // Use alignment_err
            if (alignment_err) begin
                operand_out.valid <= 0;  // Invalidate on err
            end
            // Mem response handling 
            if (hit && ack_mem) begin
                operand_out.data <= load_data;  // Forward load to output
            end
        end
    end

    // Mem ops: If L/S class, forward to d_mem_if
    always_comb begin
        if (instr_in.isa_class == `CLASS_L && fire_ready && pred_valid) begin
            load_req = 1;
            lsid = instr_in.lsid;
            addr = alu_result;  // Addr from ALU (e.g., base + imm)
        end else begin
            load_req = 0;
        end
        if (instr_in.isa_class == `CLASS_S && fire_ready && pred_valid) begin
            store_req = 1;
            lsid = instr_in.lsid;
            addr = alu_result;
            store_data = alu_result;  // Data from op (simplified; from right operand if separate)
        end else begin
            store_req = 0;
        end
    end

    // Branch handling: If B class, set branch_taken/exit_id
    always_comb begin
        if (instr_in.isa_class == `CLASS_B && fire_ready && pred_valid) begin
            branch_taken = alu_result[0];  // Cond outcome (LSB true for taken; simplified from teq/G test)
            exit_id = instr_in.exit_id;    // EXIT_ID from instr
        end else begin
            branch_taken = 0;
            exit_id = 0;
        end
    end

    // Revitalization: From morph (S-morph loop reset; preserve constants)
    //assign revitalize_internal = morph_config.revitalize_enable && (morph_config.morph_mode == `MORPH_S) && alu_valid;  // Example on output

    // Alignment err handling: Flag from reg_if, stall or error (simplified no stall)

endmodule
