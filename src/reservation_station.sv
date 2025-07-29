// reservation_station.sv
// Per E-node buffer: Frames (8-16 parametric) entries, each instr_t + 3 operand_t (left/right/pred); matches network operands to slots, fires when all valid.
// Supports revitalization (S-morph: reset valids but preserve constants via C class mask).
// Hierarchy: Contains predicate_handler (for _t/_f check on pred true).

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module reservation_station #(
    parameter FRAMES = `FRAMES_PER_NODE,     // Frames/node (8 for 128 total)
    parameter NODE_ID = 0                    // Station's ID (row*COLS + col; for match)
) (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input morph_config_t morph_config,      // Morph configuration (partitioning/revitalization)
    input instr_t instr_in,                 // Instr input from I-tile (mapped to this node)
    input operand_t operand_in,             // Operand input from network
    input instr_num_t dest_instr_in,        // input for dest instr from network (for match)
    input logic [1:0] dest_slot_in,         // input for dest slot from network (0/1/p; for case)
    input logic req_in,                     // Req input from network
    output logic ack_out,                   // Ack output to network
    output logic fire_ready,                // Fire ready output to ALU (all operands valid)
    input logic revitalize,                 // Revitalization input (S-morph reset)
    output operand_t [2:0] operands         // Operands output (left[0]/right[1]/pred[2]; fix undef ref)
);

    // Frame array: Entries per frame
    res_station_entry_t frames [FRAMES-1:0];
    logic [ $clog2(FRAMES)-1:0 ] current_frame;  // Active frame for partitioning (T-morph)

    // Operand valid flags per slot/frame (left/right/pred)
    logic [2:0] operand_valid [FRAMES-1:0];  // Bit0=left,1=right,2=pred

    // Morph handling: Partition frames for T-morph (e.g., frames/threads)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_frame <= 0;
        else if (morph_config.morph_mode == `MORPH_T) current_frame <= morph_config.num_threads;  // Simplified partition
    end
                
    instr_num_t my_instr_id; 
    assign my_instr_id = NODE_ID + current_frame * (GRID_ROWS * GRID_COLS);  //Proper ID calc (z-depth)

    // Map/store incoming operand to slot if match dest_instr (node ID) and slot
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_out <= 0;
            for (int f = 0; f < FRAMES; f++) begin
                operand_valid[f] <= '0;
            end
        end else begin
            ack_out <= 0;
            if (req_in) begin
                if (dest_instr_in == my_instr_id) begin  // Match to this station's ID (instead of opcode)
                    case (dest_slot_in)  // input dest_slot_in
                        0: begin frames[current_frame].operands[0] <= operand_in; operand_valid[current_frame][0] <= 1; end
                        1: begin frames[current_frame].operands[1] <= operand_in; operand_valid[current_frame][1] <= 1; end
                        2: begin frames[current_frame].operands[2] <= operand_in; operand_valid[current_frame][2] <= 1; end 
                    endcase
                    ack_out <= 1;
                end
            end
            // Revitalization: Reset valids but keep C class non-operands (mask non-C)
            if (revitalize && morph_config.morph_mode == `MORPH_S) begin
                for (int f = 0; f < FRAMES; f++) begin
                    if (frames[f].instr.isa_class != `CLASS_C) operand_valid[f] <= 0;  // Reset non-constants
                end
            end
        end
    end

    // Fire ready: All slots valid (pred if en)
    always_comb begin
        fire_ready = operand_valid[current_frame][0] && operand_valid[current_frame][1] &&
                     (!instr_in.predicate_en || operand_valid[current_frame][2]);
    end

    // Output operands (left/right/pred)
    assign operands = frames[current_frame].operands;

    // Instantiate predicate_handler (check _t/_f on pred_operand)
    predicate_handler predicate_handler_inst (
        .clk(clk),
        .rst_n(rst_n),
        .predicate_en(instr_in.predicate_en),   // Enable if _t/_f
        .predicate_true(instr_in.predicate_true), // 1=_t, 0=_f
        .pred_operand(frames[current_frame].operands[2]),  // operands[2] vs pred_operand
        .pred_valid(pred_valid)                 // True if condition met
    );

endmodule
