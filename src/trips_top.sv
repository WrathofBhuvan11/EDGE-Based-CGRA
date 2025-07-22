//- trips_top.sv: The trips_top.sv module acts as the main chip wrapper for the TRIPS processor, bringing together four cores, 32 memory tiles, and on-chip networks to build the full system.
//  It oversees top-level connections, clock signals, resets, and external links like memory controllers, while enabling reconfiguration for D, T, and S modes through signal propagation. This 
//  setup promotes flexibility, supporting different grid and frame sizes for block-based execution.
