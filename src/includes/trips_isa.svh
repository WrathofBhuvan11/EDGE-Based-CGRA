// trips_isa.svh
// EDGE ISA mnemonics/classes (G: add/teq; C: genu/gens/app; L/S: load/store; B: bro/callo; suffixes _t/_f)

`ifndef TRIPS_ISA_SVH
`define TRIPS_ISA_SVH

`include "trips_defines.svh"
`include "trips_types.svh"

// ISA classes (encoded in instr_t.isa_class)
`define CLASS_G     3'b000  // General ops (add, teq, etc.; 0-2 targets)
`define CLASS_I     3'b001  // Immediate ops
`define CLASS_L     3'b010  // Loads (with LSID)
`define CLASS_S     3'b011  // Stores (with LSID)
`define CLASS_B     3'b100  // Branches (with EXIT_ID, bro/callo offsets)
`define CLASS_C     3'b101  // Constants (genu/gens/app with %bit extract)

// Opcode examples (8-bit; derived from TASL samples: add, fmul, teq, mov_t, sb_t, nop, bro, callo)
`define OP_ADD      8'h01   // G: Add (targets slots)
`define OP_TEQ      8'h02   // G: Test equal (to p slot)
`define OP_FMUL     8'h03   // G: FP multiply
`define OP_MOV      8'h04   // G: Move (fanout; TASL shows up to 2 targets)
`define OP_LOAD     8'h10   // L: Load (with LSID/imm)
`define OP_STORE    8'h11   // S: Store (with LSID/imm)
`define OP_SB       8'h12   // S: Store byte (e.g., sb_t predicated)
`define OP_BRO      8'h20   // B: Branch offset
`define OP_CALLO    8'h21   // B: Call offset
`define OP_GENU     8'h30   // C: Gen unsigned constant (%bit)
`define OP_GENS     8'h31   // C: Gen signed constant (%bit)
`define OP_APP      8'h32   // C: Append constant (OR with left-shift)
`define OP_NOP      8'hFF   // No-op (implicit fill)

// Predicate suffixes (append to mnemonic: _t/_f; encoded in instr_t.predicate_true)
`define PRED_TRUE_SUFFIX   "_t"  // Execute if pred=1
`define PRED_FALSE_SUFFIX  "_f"  // Execute if pred=0

// Slot encodings (in target_t.slot)
`define SLOT_LEFT   2'b00   // Left operand (default)
`define SLOT_RIGHT  2'b01   // Right operand
`define SLOT_PRED   2'b10   // Predicate (p)

// Bit extract for C class (in instr_t.bit_extract)
`define BIT_HI      2'b00   // %hi: 63-48
`define BIT_MID     2'b01   // %mid: 47-32
`define BIT_LO      2'b10   // %lo: 31-16
`define BIT_BOTTOM  2'b11   // %bottom: 15-0

// Macro for encoding (usage in decoder/ALU)
`define ENCODE_G_OP(op, targets_array) {op, `CLASS_G, targets_array, /* etc. */ }

`endif // TRIPS_ISA_SVH
