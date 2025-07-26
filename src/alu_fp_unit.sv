// alu_fp_unit.sv
// Combined integer/FP unit: Ops for G (add/teq/fmul/div), I (imm add), C (genu/gens/app with %hi/mid/lo/bottom extract), B (cond LSB for branch_taken).
// Computes on fire (ready && pred true), 1-cycle latency (div simplified as int; FP div needs pipeline).
// Hierarchy: Standalone in e_tile; no sub-instances.
// - Integer/FP ALU per node, 1-cycle; examples add/fmul,
// - ALU for dataflow, G add/teq/fmul; C genu/gens/app with %bit for 16-bit extract from 64-bit; 

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module alu_fp_unit (
    input clk,                              // Clock input (unused for combo; ff for valid)
    input rst_n,                            // Reset input (active-low; reset valid_out)
    input logic [7:0] opcode,               // Opcode (e.g., OP_ADD/OP_TEQ/OP_DIV)
    input logic [2:0] isa_class,            // Class (CLASS_G/I/C/B)
    input operand_t [1:0] operands,         // Left[0]/right[1] operands (from res_station)
    input logic [19:0] imm_value,           // Imm for I/C (max 20-bit B but subset)
    input logic [1:0] bit_extract,          // %bit for C: 00=hi,01=mid,10=lo,11=bottom
    input logic fire,                       // Fire input (ready && pred true from res/pred_handler)
    output reg_data_t result,               // Compute result output (to routing/mem)
    output logic valid_out                  // Valid output flag (fired successfully)
);

    // Internal compute (combo for 1-cycle)
    reg_data_t left_op = operands[0].data;
    reg_data_t right_op = operands[1].data;
    logic [63:0] ext_imm;                   // Extend imm to 64 for %bit (TASL % from 64-bit)

    always_comb begin
        ext_imm = {{44{imm_value[19]}}, imm_value};  // Sign-extend 20-bit max (for gens)
        result = '0;
        case (isa_class)
            `CLASS_G: begin
                case (opcode)
                    `OP_ADD: result = left_op + right_op;  // Integer add
                    `OP_TEQ: result = (left_op == right_op) ? 32'b1 : 32'b0;  // Test eq (for cond/p)
                    `OP_FMUL: result = left_op * right_op;  // FP mul (simplified int; real ieee754)
                    `OP_DIV: begin
                        if (right_op == 0) result = '0;  // Divide-by-zero guard (set 0)
                        else result = left_op / right_op;  // Integer div (simplified 1-cycle; FP div needs pipeline)
                    end
                    default: result = '0;  // NOP/unknown
                endcase
            end
            `CLASS_I: result = left_op + imm_value;  // Imm add to left
            `CLASS_C: begin
                logic [15:0] extracted;
                case (bit_extract)
                    `BIT_HI: extracted = ext_imm[63:48];
                    `BIT_MID: extracted = ext_imm[47:32];
                    `BIT_LO: extracted = ext_imm[31:16];
                    `BIT_BOTTOM: extracted = ext_imm[15:0];
                endcase
                case (opcode)
                    `OP_GENU: result = {16'b0, extracted};  // Unsigned gen (zero-extend)
                    `OP_GENS: result = {{16{extracted[15]}}, extracted};  // Signed gen (sign-extend)
                    `OP_APP: result = (left_op << 16) | extracted;  // Append (OR with left shift)
                    default: result = '0;
                endcase
            end
            `CLASS_B: result = {31'b0, (left_op != 0)};  // Cond LSB for taken (simplified from teq/G test)
            default: result = '0;
        endcase
    end

    // Valid out: Sync on fire (1-cycle delay)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_out <= 0;
        else valid_out <= fire;
    end

endmodule