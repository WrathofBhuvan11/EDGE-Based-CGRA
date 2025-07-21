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
### ======================================================================

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



















### Future Directions
This project can be extended by:

- Adding support for new functional units, such as specialized DSP or machine learning accelerators.
- Implementing advanced interconnect topologies to optimize data transfer.
- Developing a compiler or mapping tool to automate the scheduling of computations and data routing.
- Integrating with frameworks for enhanced modeling and evaluation capabilities.
- Want to develop it into Robotics edge Chip for real-time inference
