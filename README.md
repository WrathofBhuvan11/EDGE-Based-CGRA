## EDGE based TRIPS - CGRA Project
## Introduction
A Coarse-Grained Reconfigurable Array (CGRA) is a versatile hardware architecture designed to accelerate compute-intensive applications by leveraging parallelism. It consists of an array of processing elements (PEs) that can be dynamically or statically reconfigured to perform various computations, offering a balance between the flexibility of software and the performance of dedicated hardware. This project implements a CGRA to explore its potential in high-performance, energy-efficient computing for applications such as future robotics inference, digital signal processing, machine learning, and multimedia processing.

TRIPS is one such architecture sub category. It follows EDGE ISA.

## TRIP Microarchitecture EDGE - Explicit data graph execution
The microarchitecture of this CGRA project is designed to be modular and configurable, enabling flexibility for various computational tasks. EDGE combines many individual instructions into a larger group known as a "hyperblock". Hyperblocks are designed to be able to easily run in parallel. TRIPS is a processor based on the Explicit Data Graph Execution (EDGE) ISA.

## TRIPS Processor Architecture Overview
The TRIPS (Tera-op, Reliable, Intelligently adaptive Processing System) architecture is an experimental microprocessor design developed at the University of Texas at Austin as part of DARPA's Polymorphous Computing Architectures (PCA) program in the early 2000s. It serves as a prototype implementation of the Explicit Data Graph Execution (EDGE) Instruction Set Architecture (ISA), aiming to achieve high levels of instruction-level parallelism (ILP), thread-level parallelism (TLP), and data-level parallelism (DLP) while maintaining energy efficiency and adaptability. TRIPS addresses challenges like growing wire delays, power limits, and diminishing clock scaling in traditional processors (e.g., RISC/CISC).

This explanation is tailored for a GitHub README, assuming an audience familiar with basic computer architecture (e.g., ECE undergrads). It draws from the provided paper "Compiling for EDGE Architectures" (2004) and related references. For implementation details, refer to the SystemVerilog modules in this repo.

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
trips_top.sv (Top: Chip; Instances: trips_core_inst[0:3] (4 cores), mem_tile_inst[0:31] (32 tiles), onchip_mem_network_inst (1))
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
├── mem_tile.sv (Instances: mem_tile_inst[0:31]; Count: 32)  // 32KB each; polymorph (cache/scratchpad/SRF)
└── onchip_mem_network.sv (Instance: mem_net; Count: 1)  // Switched 2D; wide channels for SRF (S-morph)
```
#### 1.  trips_top.sv: Top-level module; instantiates all tiles, interconnects, clocks/resets. Ports: External memory interface, debug.
#### 2.  g_tile.sv: Global control logic; block tracker, branch predictor, fetch controller.
#### 3.  r_tile.sv: Register bank module (parameterized for 4 instances); includes buffering for reads/writes.
#### 4.  e_tile.sv: Execution tile; ALU, reservation station (queue for up to 128/16=8 instr per tile avg), operand matcher.
#### 5.  i_tile.sv: Instruction cache; fetch/decode logic, block header parser (for store masks).
#### 6.  d_tile.sv: Data cache; LSID-based ordering queue, load/store unit.
#### 7.  switching_network.sv: Mesh interconnect for operand routing (routers per tile, 1-cycle hops).
#### 8.  reservation_station.sv: Sub-module for E-tiles; holds instructions, checks operand readiness.
#### 9.  alu.sv: Parameterized ALU (add, sub, mul, etc.; support predicates).
#### 10.  lsid_unit.sv: For D-tile; handles LSID assignment validation and ordering.
#### 11.  block_controller.sv: Manages block atomicity, completion detection (count outputs).

Include files
Include Files (.svh)
These are headers for constants, interfaces, structs (non-synth, used in modules):

#### 1. trips_defines.svh: Constants (e.g., BLOCK_SIZE=128, NUM_BANKS=4, LSID_BITS=5, GRID_SIZE=4).
#### 2. trips_types.svh: Typedefs/structs (e.g., instruction format: opcode, targets; operand struct).
#### 3. trips_interfaces.svh: Interface defs (e.g., for tile-to-tile comm: operand ports, control signals).
#### 4. trips_isa.svh: EDGE ISA encodings (e.g., ADD target syntax, NULL instr, MOV fanout).
#### 5. trips_params.svh: Parameter defaults (e.g., REG_COUNT=128, CACHE_SIZE=2048)








