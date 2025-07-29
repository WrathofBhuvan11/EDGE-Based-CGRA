// isa_decoder.sv
// Instruction decoder: Parses raw 32-bit word to instr_t (class/opcode/targets/slot/pred/LSID/imms/%bit).
// Assumes bit layout (inferred: [31:29 res, 29 pred_en, 27 pred_true, 26:24 class, 23:19 lsid/exit, 18:0 imm/bit; targets packed in imm for G).
// Auto LSID/EXIT_ID if 0 (counter; TASL Sec. 4.5.1.3).
// Hierarchy: Standalone in i_tile; no sub-instances.

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module isa_decoder (
    input clk,                      // Clock input
    input rst_n,                    // Reset input
    input logic fetch_new_block,    // input for new block fetch signal (from G via I-tile)
    input logic [31:0] raw_instr,   // Raw 32-bit instr input from cache
    output instr_t decoded_instr    // Decoded instr_t output
);

    // Internal counters for auto LSID/EXIT_ID (per block; reset on new block via G signal, assumed external)
    logic [4:0] lsid_auto_counter, exit_auto_counter;

    // Combo decode (unpack bits to struct)
    always_comb begin
        // Assumed layout (inferred; adjust per full spec): [31:29 res][28 pred_en][27 pred_true][26:24 class][23:19 lsid/exit][18:0 imm/bit/op subset]
        decoded_instr.opcode = raw_instr[7:0];  // Low 8 for opcode
        decoded_instr.isa_class = raw_instr[26:24];  // Class 3-bit
        decoded_instr.predicate_en = raw_instr[28];  // Pred en
        decoded_instr.predicate_true = raw_instr[27];  // _t=1, _f=0
        decoded_instr.lsid = raw_instr[23:19];       // LSID 5-bit
        decoded_instr.exit_id = raw_instr[23:19];    // EXIT_ID (shared field for B)
        decoded_instr.imm_value = raw_instr[19:0];   // Imm 20-bit max
        decoded_instr.bit_extract = raw_instr[21:20];  // %bit 2-bit for C
        // Targets: Assumed packed in imm for G (simplified; real separate fields/encoding)
        decoded_instr.targets[0].target_instr = raw_instr[15:8];  // Target0 num
        decoded_instr.targets[0].slot = raw_instr[1:0];    // Slot
        decoded_instr.targets[0].valid = 1;                       // Assume valid if non-zero
        decoded_instr.targets[1].target_instr = raw_instr[23:16]; // Target1 (example overlap; adjust)
        decoded_instr.targets[1].slot = raw_instr[3:2];
        decoded_instr.targets[1].valid = raw_instr[23:16] != 0;

        // Auto LSID/EXIT_ID if 0 (increment counters)
        if (decoded_instr.isa_class inside {`CLASS_L, `CLASS_S} && decoded_instr.lsid == 0) begin
            decoded_instr.lsid = lsid_auto_counter;
        end
        if (decoded_instr.isa_class == `CLASS_B && decoded_instr.exit_id == 0) begin
            decoded_instr.exit_id = exit_auto_counter;
        end
    end

    // Counter increment (sequential always_ff)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || fetch_new_block) begin
            lsid_auto_counter <= 0;
            exit_auto_counter <= 0;
        end else begin
            if (decoded_instr.isa_class inside {`CLASS_L, `CLASS_S} && decoded_instr.lsid == 0) begin
                lsid_auto_counter <= lsid_auto_counter + 1;
            end
            if (decoded_instr.isa_class == `CLASS_B && decoded_instr.exit_id == 0) begin
                exit_auto_counter <= exit_auto_counter + 1;
            end
        end
    end
endmodule
