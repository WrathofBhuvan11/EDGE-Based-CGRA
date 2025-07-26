// trips_params.svh
// Parameter defaults for TRIPS modules (scalable grid/frames/morphs)

`ifndef TRIPS_PARAMS_SVH
`define TRIPS_PARAMS_SVH

`include "trips_defines.svh"

// Default parameters
parameter int GRID_ROWS = `GRID_ROWS;              // 4 rows
parameter int GRID_COLS = `GRID_COLS;               // 4 columns
parameter int FRAMES_PER_NODE = `FRAMES_PER_NODE;  // 8 frames/node (128 total slots)
parameter int REG_COUNT = 128;                      // Total architectural regs G[0-127]
parameter int QUEUE_DEPTH = 32;                     // R/W queues [0-31]
parameter int CACHE_SIZE = `D_CACHE_SIZE;           // Default D-cache size (2KB L1)
parameter int I_CACHE_SIZE = `I_CACHE_SIZE;         // I-cache size (6KB)
parameter int L2_TILE_SIZE = `L2_TILE_SIZE;         // 32KB/tile
parameter int NUM_L2_TILES = `NUM_L2_TILES;         // 32 tiles (1MB)
parameter int ALU_WIDTH = 32;                       // Data width (32-bit)
parameter int RES_STATION_SLOTS = 3;                // Per entry: left/right/pred
parameter int NETWORK_HOPS_MAX = 3;                 // Max hops in 4x4 grid (~3 diameter)
parameter int BANK_ID_WIDTH = 2;                    // 2 bits for 4 banks
parameter int MORPH_MODE_DEFAULT = `MORPH_D;        // Default morph: D (ILP)


parameter NUM_CORES = 4;                // Cores connected (prototype: 4)
parameter ADDR_WIDTH = 32;              // Address width
parameter FLIT_SIZE = 64;               // Flit size (bits; for multi-flit packets)

parameter NUM_PORTS = 5;
parameter NORTH = 0, SOUTH = 1, EAST = 2, WEST = 3, LOCAL = 4;


`endif // TRIPS_PARAMS_SVH
