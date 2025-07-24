## EDGE based TRIPS - CGRA Project
**work is ongoing
## Introduction
A Coarse-Grained Reconfigurable Array (CGRA) is a versatile hardware architecture designed to accelerate compute-intensive applications by leveraging parallelism. It consists of an array of processing elements (PEs) that can be dynamically or statically reconfigured to perform various computations, offering a balance between the flexibility of software and the performance of dedicated hardware. This project implements a CGRA to explore its potential in high-performance, energy-efficient computing for applications such as future robotics inference, digital signal processing, machine learning, and multimedia processing.

TRIPS is one such architecture sub category. It follows EDGE ISA.

## TRIPS Microarchitecture EDGE - Explicit data graph execution
The microarchitecture of this CGRA project is designed to be modular and configurable, enabling flexibility for various computational tasks. EDGE combines many individual instructions into a larger group known as a "hyperblock". Hyperblocks are designed to be able to easily run in parallel. TRIPS is a processor based on the Explicit Data Graph Execution (EDGE) ISA.
<img width="746" height="257" alt="image" src="https://github.com/user-attachments/assets/04a85cea-e6f4-43d0-961f-31ab7e583680" />

## TRIPS Processor Architecture Overview
The TRIPS (Tera-op, Reliable, Intelligently adaptive Processing System) architecture is an experimental microprocessor design developed at the UT at Austin as part of DARPA's Polymorphous Computing Architectures (PCA) program in the early 2000s. It serves as a prototype implementation of the Explicit Data Graph Execution (EDGE) Instruction Set Architecture (ISA), aiming to achieve high levels of instruction-level parallelism (ILP), thread-level parallelism (TLP), and data-level parallelism (DLP) while maintaining energy efficiency and adaptability. TRIPS addresses challenges like growing wire delays, power limits, and diminishing clock scaling in traditional processors (e.g., RISC/CISC).

Morph refers to a polymorphic reconfiguration mode in the TRIPS architecture, allowing the processor to adapt its hardware resources (like frame space and memory tiles) to exploit different types of parallelism efficiently. The three morphs are D-morph (Desktop morph for instruction-level parallelism or ILP, optimized for single-threaded desktop applications with large issue windows and speculation), T-morph (Threaded morph for thread-level parallelism or TLP, partitioning resources for multiple threads to improve utilization on multiprogrammed workloads), and S-morph (Streaming morph for data-level parallelism or DLP, configuring memory as stream register files with loop revitalization for vector/streaming codes).hpcwire.com They are named this way to reflect their primary application domains: "D" for desktop/ILP focus on general-purpose single-thread performance, "T" for threaded/TLP emphasis on concurrent threads, and "S" for streaming/DLP targeting data-parallel loops like media processing, aligning with the goal of bridging processor fragility across workloads as per the polymorphous paper.
<img width="1292" height="399" alt="image" src="https://github.com/user-attachments/assets/6ba4d422-382d-4f2b-a92f-735f04f0a4a5" />

## TRIPS intro?
TRIPS is a tiled, grid-based processor designed for polymorphic execution—dynamically adapting to different workloads (e.g., single-threaded ILP-heavy tasks or vectorized DLP for AI/math). It targets tera-op performance (trillions of operations per second) on a single chip, using a distributed microarchitecture to minimize global communication and power consumption.

## What is EDGE ISA?
EDGE (Explicit Data Graph Execution) is the ISA powering TRIPS. It's a hybrid dataflow model:
Programs are compiled into atomic hyperblocks (up to 128 instructions each), forming a data graph where dependencies are explicitly encoded.
Instructions don't use traditional registers for intra-block communication; instead, producers directly target consumers (e.g., "ADD result to instr 126's left operand").
Execution is block-atomic: Fetch/execute/commit as a unit, with dynamic issue (out-of-order within block when operands ready).
Constraints for hardware simplicity (from the paper):
* Max 128 instructions/block.
* Max 32 loads/stores (using 5-bit LSIDs for ordering).
* Max 32 register reads/writes (8 per bank across 4 banks).
* Constant outputs: Fixed number of stores, writes, and 1 branch per block.
### ==========================================================
### RTL files planned - 
```
trips_processor.sv (Top: Chip; Instances: trips_core_inst[0:3] (4 cores), mem_tile_inst[0:31] (32 tiles), onchip_mem_network_inst (1))
├── trips_core.sv (Instance: trips_core_inst[0:3]; Count: 4)  // Per core: Grid + tiles
│   ├── g_tile.sv (Instance: g_tile_inst; Count: 1)  // Block ctrl, speculation (8 blocks), morph config
│   │   └── block_controller.sv (Instance: block_ctrl; Count: 1)  // Atomicity, revitalization (S-morph), EXIT_ID
│   ├── r_tile.sv (Instances: r_tile_bank[0:3]; Count: 4)  // Banks; queues R/W[0-31], alignment mod 4
│   ├── e_tile.sv (Instances: e_tile_grid[0:3][0:3]; Count: 16)  // Grid nodes; frames=8
│   │   ├── alu_fp_unit.sv (Instance: alu_fp_inst; Count: 1/node)  // G/I/C ops, %bit extract (hi/mid/lo/bottom)
│   │   └── reservation_station.sv (Instance: res_station; Count: 1/node)  // 3 slots (left/right/p), dataflow fire
│   │       └── predicate_handler.sv (Instance: pred_handler; Count: 1)  // _t/_f check, p slot routing
│   ├── i_tile.sv (Instance: i_tile_inst; Count: 1)  // I-cache; TASL decode
│   │   └── isa_decoder.sv (Instance: isa_dec; Count: 1)  // Classes (G/I/L/S/B/C), predicates, LSID/EXIT_ID, sequence <num>
│   ├── d_tile.sv (Instance: d_tile_inst; Count: 1)  // D-cache; LSID queues (32)
│   │   └── lsid_unit.sv (Instance: lsid_handler; Count: 1)  // Ordering for L/S classes
│   └── switching_network.sv (Instance: operand_net; Count: 1)  // Mesh routers; targets (N/W, 0/1/p slots)
|       └── router.sv (Instance router_inst- 5-port XY with RR arb, wormhole, buffers)
├── mem_tile.sv (Instances: mem_tile_inst[0:31]; Count: 32)  // 32KB each; polymorph (cache/scratchpad/SRF)
└── onchip_mem_network.sv (Instance: mem_net; Count: 1)  // Switched 2D; wide channels for SRF (S-morph)
    └── router.sv (Instance router_inst- 5-port XY with RR arb, wormhole, buffers)
```
#### - trips_top.sv: The trips_top.sv module acts as the main chip wrapper for the TRIPS processor, bringing together four cores, 32 memory tiles, and on-chip networks to build the full system. It oversees top-level connections, clock signals, resets, and external links like memory controllers, while enabling reconfiguration for D, T, and S modes through signal propagation. This setup promotes flexibility, supporting different grid and frame sizes for block-based execution.

#### - trips_core.sv: The trips_core.sv module defines one adaptable core, including the 4x4 execution grid, G, R, I, and D tiles, plus internal networks, with settings that adjust for modes like frame splitting for threads or stream support for data parallelism. It manages dataflow inside the core by directing operands and controls, allowing up to 128 instructions per block via frame management. Its flexible design makes scaling to bigger grids straightforward, fitting various row, column, and frame setups.

#### - g_tile.sv: The g_tile.sv module provides overall control for handling blocks, fetching them from the I-tile, completing outputs based on fixed counts, and managing guesses for up to eight active blocks with branch handling. It sets up modes by allocating frames and reset signals for stream loops, keeping operations atomic and handling interrupts at block ends. This tile works with the block controller to spot endings and clear wrong guesses, aiding single-thread speed in desktop mode.

#### - r_tile.sv: The r_tile.sv module handles one of four register groups, each with 32 spots for a total of 128 main registers, including read and write lines and checks to ensure proper bank lineup. It stores up to 32 reads or writes per block, passing values to and from the execution grid while keeping data between blocks. The design keeps registers steady across modes without extra setup costs.

#### - e_tile.sv: The e_tile.sv module creates a single grid spot for running commands, with mixed integer and floating-point units, storage slots holding eight to sixteen frames, and logic for conditions like true or false checks. It has built-in routers for quick value passing and handles time-sharing frames for big command groups or splitting in thread and stream modes. This setup lets commands start when ready, key to the direct flow style.

#### - i_tile.sv: The i_tile.sv module runs the split instruction storage at 6KB, pulling and breaking down block groups into command forms, spotting types, conditions, order tags, order numbers, and bit pulls for fixed values. It assigns commands to grid storage spots, dealing with block starters for output counts and mode-based pulling like loop repeats in stream mode. The module boosts sending speed and backs guessing by grabbing extra blocks ahead.

#### - d_tile.sv: The d_tile.sv module controls the split first-level data storage at 2KB and links to second-level split storage, with order lines for sorted pulls and pushes up to 32 per block. It switches modes to act as regular storage for desktop or thread uses, or as stream files with wide paths and scatter-gather for data-parallel tasks. The tile deals with matches or misses at two ticks for first-level hits and finishes pushes when blocks end.

#### - switching_network.sv: The switching_network.sv module builds the light value-passing grid inside the core, with spot-based directors for one-tick jumps using position shifts, backing up to two end points per command. It aids block-inner talk without wide lines and scales for bigger grids without mode changes or extra costs. This setup cuts wire waits, vital for speed.

#### - onchip_mem_network.sv: The onchip_mem_network.sv module sets up the switched 2D link for core to storage spot access, giving flexible speed to 32 spots of 32KB each for second-level or stream use. It manages spot directing and mode signals, keeping quick access without labels in stream mode for flow data. The network backs many cores and spreads work across spots.

#### - mem_tile.sv: The mem_tile.sv module makes a 32KB storage spot that switches to second-level group with labels for desktop or thread modes, plain scratch, or stream file with straight entry and wide 256-bit paths to near cores for data-parallel work. It has built machines for swapping, scatter-gather, and sync holds, linking through the chip network. Each spot's bend helps keep data close and cuts outside pulls.

#### - reservation_station.sv: The reservation_station.sv module per grid spot runs frame slots at eight to sixteen each, with three value places for flow matching, starting commands when set and dealing with true or false checks. It backs stream mode resets without remapping to keep fixed values and splitting for thread mode groups. The depth lets big windows at 128 spots per core, key for command-parallel speed in desktop mode.

#### - alu_fp_unit.sv: The alu_fp_unit.sv module mixes number and float actions for main, quick, and fixed types, including adds, equals tests, multiplies, fixed makers with bit pulls for 16-bit parts from 64-bit values, and no-actions. It works conditions and places, sending to end points through the network. This unit fits all modes without shifts, aiming at quick run at one tick.

#### - isa_decoder.sv: The isa_decoder.sv module in the pull tile breaks taken commands into forms, spotting types, actions, end points up to two with places, conditions, order tags that can be skipped, quick values at nine to twenty bits, and bit pulls for fixed type. It deals with order numbers for choice ordering and assigns to storage spots. The breaker makes sure of rules like one jump per block, aiding block-whole breaking.

#### - block_controller.sv: The block_controller.sv module in the control tile forces whole by tallying fixed outputs like pushes via starter mask, writes, and one jump, running stream mode loop resets to hold fixed values, and frame sharing for switching like big groups for desktop or per-thread for threaded. It handles guesses with clears on wrong predict or exit, branch order solving, and break accuracy at edges. This director is main for mode shifts and speed over command, thread, and data parallel.

Include files
Include Files (.svh)
These are headers for constants, interfaces, structs (non-synth, used in modules):

#### 1. trips_defines.svh: Constants (e.g., BLOCK_SIZE=128, NUM_BANKS=4, LSID_BITS=5, GRID_SIZE=4).
#### 2. trips_types.svh: Typedefs/structs (e.g., instruction format: opcode, targets; operand struct).
#### 3. trips_interfaces.svh: Interface defs (e.g., for tile-to-tile comm: operand ports, control signals).
#### 4. trips_isa.svh: EDGE ISA encodings (e.g., ADD target syntax, NULL instr, MOV fanout).
#### 5. trips_params.svh: Parameter defaults (e.g., REG_COUNT=128, CACHE_SIZE=2048)
