// trips_types.svh
// Typedefs and structs for TRIPS EDGE Architecture (ISA classes G/I/L/S/B/C, predicates, bit extract)

`ifndef TRIPS_TYPES_SVH
`define TRIPS_TYPES_SVH

`include "trips_defines.svh"
`include "trips_params.svh"

// Basic types
typedef logic [31:0] reg_data_t;    // 32-bit register/operand data (assuming 32-bit arch)
typedef logic [(`INSTR_NUM_BITS-1):0] instr_num_t;  // Instruction number within block (0-127)
typedef logic [(`LSID_BITS-1):0] lsid_t;            // Load/Store ID
typedef logic [(`EXIT_ID_BITS-1):0] exit_id_t;      // Branch EXIT_ID

// Operand struct: For reservation stations and routing
typedef struct packed {
    reg_data_t data;                // Operand value
    logic valid;                    // Is operand ready?
    instr_num_t source_instr;       // Source instruction number (for debugging)
} operand_t;

// Target field: EDGE targets (up to 2 per instr from TASL examples; slot: 0=left,1=right,p=pred)
typedef struct packed {
    instr_num_t target_instr;       // Target instruction number (or W queue)
    logic [1:0] slot;               // Slot: 00=left (default), 01=right, 10=pred (p), 11=reserved
    logic is_write_queue;           // 1 if W[queue], 0 if N[node]
    logic valid;                    // Is this target used?
} target_t;

// Instruction format struct: EDGE classes (G/I/L/S/B/C; no sources, explicit targets)
typedef struct packed {
    logic [7:0] opcode;             // Opcode (8 bits, derived; extend as needed)
    logic [2:0] isa_class;          // Class: 000=G, 001=I, 010=L, 011=S, 100=B, 101=C, others reserved
    target_t [1:0] targets;         // Up to 2 targets (TASL examples show 0-2; fanout limited)
    logic predicate_en;             // Predicate enable (_t/_f suffixes)
    logic predicate_true;           // 1=true (_t), 0=false (_f)
    operand_t pred_operand;         // Predicate operand (if enabled)
    lsid_t lsid;                    // LSID for L/S (optional, default auto)
    exit_id_t exit_id;              // EXIT_ID for B (optional, default auto)
    logic [19:0] imm_value;         // Max imm (20-bit for B; subset for I=9-bit, C=16-bit)
    logic [1:0] bit_extract;        // For C class %ops: 00=hi(63-48), 01=mid(47-32), 10=lo(31-16), 11=bottom(15-0)
    logic [4:0] reg_id;             // Register ID for reads/writes (5 bits for 32 queues/bank)
} instr_t;

// Block header struct: For fetch/completion
typedef struct packed {
    logic [31:0] store_mask;        // 32-bit mask for expected stores (constant outputs)
    logic [5:0] num_reg_writes;     // Expected register writes (up to 32)
    logic block_valid;              // Block ready to execute
    logic [1:0] morph_mode;         // Morph config: 00=D, 01=T, 10=S
} block_header_t;

// Reservation station entry (per frame/node)
typedef struct packed {
    instr_t instr;                  // The instruction
    operand_t [2:0] operands;       // Left, right, pred operands
    logic ready;                    // Ready to issue?
} res_station_entry_t;

 // Generic flit (union-like; conditional fields via param FLIT_TYPE: 0=operand,1=mem)
typedef struct packed {
    operand_t operand;                  // Operand data/valid/source (operand net)
    instr_num_t dest_instr;             // Dest instr (operand)
    logic [1:0] dest_slot;              // Slot (operand)
    logic [ADDR_WIDTH-1:0] addr;        // Addr (mem net)
    logic is_read;                      // Read/write (mem)
    logic is_wide;                      // Wide (mem S-morph)
    logic [1:0] transfer_type;          // Transfer (mem)
    logic [15:0] payload_size;          // Payload (mem multi-flit)
    logic [FLIT_SIZE-1:0] data;         // Data (mem)
    logic last_flit;                    // Last flit (mem)
    logic ipriority;                     // Priority (both; higher for mem wide)
    logic [$clog2(NUM_CORES)-1:0] src_core;  // Src core (mem response)
} generic_flit_t;
 
`endif // TRIPS_TYPES_SVH

