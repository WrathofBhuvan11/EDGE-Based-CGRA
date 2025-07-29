/*
trips_processor.sv
Top-level chip wrapper for TRIPS processor: Instantiates 4 cores (prototype), 32 memory tiles, and on-chip memory network.
Manages high-level interconnections, clock/reset distribution, external interfaces (example- memory controllers), and polymorphism signals.
Scalable via parameters for grid size, frames, morph modes; supports block-atomic execution across morphs (D/T/S).
Hierarchy: Top container for trips_core[0:3], mem_tile[0:31], onchip_mem_network.
*/

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module trips_processor #(
    parameter NUM_CORES = 4,                // Prototype: 4 polymorphous cores
    parameter NUM_MEM_TILES = `NUM_L2_TILES // 16 tiles for 1MB on-chip memory
) (
    input clk,                              // Global clock
    input rst_n,                            // Active-low reset
    // External memory interface (example, DDR controllers; simplified)
    input logic [31:0] ext_mem_addr,        // Address from/to external memory
    input logic ext_mem_rd_req,             // Read request
    input logic ext_mem_wr_req,             // Write request
    input reg_data_t ext_mem_wr_data,       // Write data
    output reg_data_t ext_mem_rd_data,      // Read data
    output logic ext_mem_ack,               // Acknowledge
    // Morph configuration input (example, from software/OS; for polymorphism)
    input logic [1:0] global_morph_mode,    // D/T/S mode for all cores
    // Debug/trace ports 
    output logic debug_commit,              // Block commit signal
    output logic [31:0] debug_pc            // Current block PC
);

    // Internal signals and interfaces
    // Control interfaces for morph propagation (one per core)
    control_if core_control_if [NUM_CORES-1:0] ();
    // Memory network interfaces (cores to mem network)
    mem_tile_if core_to_mem_if [NUM_CORES-1:0] ();
    // Mem tile interfaces (network to tiles)
    mem_tile_if mem_net_to_tile_if [NUM_MEM_TILES-1:0] ();
    // External mem interface (from network to off-chip)
    mem_tile_if ext_mem_if ();              // Simplified single channel

    // Global morph config broadcast (propagate to all cores/tiles)
    morph_config_t global_config;
    always_comb begin
        case (global_morph_mode)
            `MORPH_D: global_config = `D_MORPH_CONFIG;
            `MORPH_T: global_config = `T_MORPH_CONFIG;
            `MORPH_S: global_config = `S_MORPH_CONFIG;
            default: global_config  = `D_MORPH_CONFIG;  // Default to D-morph
        endcase
    end

    // Instantiate 4 TRIPS cores (parametric for polymorphism)
    genvar core_idx;
    generate
        for (core_idx = 0; core_idx < NUM_CORES; core_idx++) begin : gen_cores
            trips_core #(
                .CORE_ID(core_idx)              // Unique core ID for addressing
            ) trips_core_inst (
                .clk(clk),
                .rst_n(rst_n),
                .morph_config(global_config),   // Propagate global morph config
                .control_if(core_control_if[core_idx]),  // Control for fetch/commit
                .mem_tile_if(core_to_mem_if[core_idx]),  // To on-chip mem network
                .debug_commit(debug_commit),    // Per-core debug (aggregate if needed)
                .debug_pc(debug_pc)             // Simplified: Last core's PC for debug
            );
        end
    endgenerate

    // Instantiate 32 memory tiles (configurable for cache/scratchpad/SRF)
    genvar tile_idx;
    generate
        for (tile_idx = 0; tile_idx < NUM_MEM_TILES; tile_idx++) begin : gen_mem_tiles
            mem_tile #(
                .TILE_ID(tile_idx),             // Unique tile ID
                .TILE_SIZE(`L2_TILE_SIZE)       // 32KB each
            ) mem_tile_inst (
                .clk(clk),
                .rst_n(rst_n),
                .morph_config(global_config),   // Config for SRF in S-morph (example- no tags, direct access)
                .mem_tile_if(mem_net_to_tile_if[tile_idx]),  // From on-chip network
                // Wide SRF channels if adjacent to cores (simplified: assume first 4 tiles adjacent)
                .srf_wide_data((tile_idx < NUM_CORES) ? core_to_mem_if[tile_idx].wr_data_wide : '0), 
                .srf_wide_valid((tile_idx < NUM_CORES) && global_config.srf_enable)
            );
        end
    endgenerate

    // Instantiate on-chip memory network (switched 2D for core-tile comm)
    onchip_mem_network #(
        .NUM_CORES(NUM_CORES),
        .NUM_TILES(NUM_MEM_TILES)
    ) onchip_mem_network_inst (
        .clk(clk),
        .rst_n(rst_n),
        .core_mem_if(core_to_mem_if),           // From cores
        .tile_mem_if(mem_net_to_tile_if),       // To tiles
        .ext_mem_if(ext_mem_if),                // To external (off-chip) memory
        .morph_config(global_config)            // For SRF routing enhancements in S-morph
    );

    // External memory interface logic (simplified stub; connect to DDR/etc.)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_mem_rd_data <= '0;
            ext_mem_ack <= 0;
        end else begin
            if (ext_mem_rd_req) begin
                // Simulate read from external (placeholder; integrate real controller)
                ext_mem_rd_data <= ext_mem_addr;  // Echo addr as data for test
                ext_mem_ack <= 1;
            end else if (ext_mem_wr_req) begin
                // Simulate write (no-op)
                ext_mem_ack <= 1;
            end else begin
                ext_mem_ack <= 0;
            end
        end
    end

    // Debug aggregation (simplified: OR commits, use core 0 PC)
    always_comb begin
        debug_commit = |{core_control_if[0].commit, core_control_if[1].commit, core_control_if[2].commit, core_control_if[3].commit};
        debug_pc = core_control_if[0].block_addr;  // Example: Core 0's current block addr
    end


endmodule: trips_processor
