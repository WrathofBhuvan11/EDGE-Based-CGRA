// trips_defines.svh
// Constants (BLOCK_SIZE=128, GRID=4x4x8, LSID_BITS=5, BANKS=4).
// Constants for TRIPS EDGE Architecture based on PDFs (prototype: 4x4 grid, 8 frames, 128 slots)

`ifndef TRIPS_DEFINES_SVH
`define TRIPS_DEFINES_SVH

// Block constraints (from compiler paper: max 128 instr/block; TASL manual confirms)
`define BLOCK_SIZE          128     // Max instructions per hyperblock (4x4x8)
`define MAX_LOADS_STORES    32      // Max loads/stores per block (5-bit LSID)
`define MAX_REG_READS       32      // Max register reads per block (8/bank x4)
`define MAX_REG_WRITES      32      // Max register writes per block (8/bank x4)
`define MAX_INFLIGHT_BLOCKS 8       // Max blocks in flight for speculation

// Grid and tile dimensions (polymorphous paper: 4x4 prototype, scalable; TASL: rows/cols powers of 2, frames 1-256)
`define GRID_ROWS           4       // Rows in ALU grid
`define GRID_COLS           4       // Columns in ALU grid
`define FRAMES_PER_NODE     8       // Physical frames per execution node (z-depth)
`define NUM_E_NODES         (`GRID_ROWS * `GRID_COLS)  // 16 Execution nodes
`define NUM_REG_BANKS       4       // 4 register banks
`define REGS_PER_BANK       32      // 32 registers per bank (total 128)

// LSID/EXIT_ID and bit widths (compiler: 5-bit LSID; TASL: optional LSID/EXIT_ID, defaults generated)
`define LSID_BITS           5       // 5-bit LSID for load/store ordering (2^5=32)
`define EXIT_ID_BITS        5       // 5-bit EXIT_ID for branches (assumed similar to LSID)
`define INSTR_NUM_BITS      7       // 7-bit instruction number (for 128 instr/block, 2^7=128)

// Cache and memory parameters (polymorphous paper: 6KB I-cache, 2KB L1 D-cache, 1MB NUCA L2 via 32x32KB tiles)
`define I_CACHE_SIZE        6144    // 6KB I-cache (banked per row)
`define D_CACHE_SIZE        2048    // 2KB L1 D-cache (banked)
`define L2_TILE_SIZE        32768   // 32KB per memory tile
`define NUM_L2_TILES        32      //32 tiles for 1MB NUCA L2/SRF

// Execution latencies (cycles, from polymorphous paper simulations)
`define ALU_LATENCY         1       // Basic ALU op
`define D_CACHE_HIT_LATENCY 2       // D-cache hit
`define I_CACHE_HIT_LATENCY 1       // I-cache hit
`define BLOCK_FETCH_LATENCY 8       // Block fetch
`define NETWORK_HOP_LATENCY 1       // Per-hop in operand network
`define REVITALIZATION_LATENCY 1    // S-morph loop revitalization delay (assumed minimal)

// Other constants (TASL: big-endian, sequence nums optional)
`define NUM_OUTPUTS_FIXED   1       // Exactly one branch per block
`define PREDICATE_BIT       1       // Predicate field (true/false, LSB)
`define BYTE_ORDER_BIG_ENDIAN 1     // Big-endian byte ordering

// Morph modes (polymorphous paper: D/T/S)
`define MORPH_D             0       // Desktop/ILP morph
`define MORPH_T             1       // Threaded/TLP morph
`define MORPH_S             2       // Streaming/DLP morph

`endif // TRIPS_DEFINES_SVH
