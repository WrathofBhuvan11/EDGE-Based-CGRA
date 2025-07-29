// trips_config.svh
// Morph configurations for TRIPS polymorphism (frame partitions, mem modes for D/T/S)

`ifndef TRIPS_CONFIG_SVH
`define TRIPS_CONFIG_SVH

`include "trips_defines.svh"
`include "trips_params.svh"

// Morph config struct (set via control_if.morph_mode)
typedef struct packed {
    logic [1:0] morph_mode;         // Added: Explicit mode (00=D, 01=T, 10=S)
    logic [7:0] aframe_size;        // A-frame slots (e.g., max 128 for D-morph)
    logic [3:0] num_threads;        // For T-morph (up to 8 threads/core)
    logic srf_enable;               // Enable SRF mode for mem tiles (S-morph)
    logic [4:0] srf_banks;          // SRF banks (subset of L2 tiles)
    logic revitalize_enable;        // S-morph loop revitalization
    logic speculation_depth;        // D-morph speculation (up to 8 blocks)
} morph_config_t;

// Default configs per morph (updated with morph_mode)
`define D_MORPH_CONFIG '{morph_mode: `MORPH_D, aframe_size: 128, num_threads: 1, srf_enable: 0, srf_banks: 0, revitalize_enable: 0, speculation_depth: 8}
`define T_MORPH_CONFIG '{morph_mode: `MORPH_T, aframe_size: 16, num_threads: 8, srf_enable: 0, srf_banks: 0, revitalize_enable: 0, speculation_depth: 1}  // Example: 16 slots/thread x8
`define S_MORPH_CONFIG '{morph_mode: `MORPH_S, aframe_size: 128, num_threads: 1, srf_enable: 1, srf_banks: 4, revitalize_enable: 1, speculation_depth: 0}  // SRF with revitalization


`endif // TRIPS_CONFIG_SVH
