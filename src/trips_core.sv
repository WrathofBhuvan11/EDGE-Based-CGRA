/*
trips_core.sv
Single polymorphous TRIPS core: Encapsulates 4x4 execution grid (E-nodes), G/R/I/D tiles, and operand network.
Parametric for morphs (D: large A-frames/speculation; T: frame partitions/threads; S: SRF/revitalization).
Handles intra-core dataflow (explicit targets, no sources intra-block), block-atomic execution (fetch/map/execute/commit).
Hierarchy: Instantiates g_tile (with block_controller), 
                        r_tile[0:3], 
                        e_tile[0:3][0:3] (with alu_fp_unit, res_station incl. predicate_handler), 
                        i_tile (with isa_decoder), 
                        d_tile (with lsid_unit), 
                        switching_network
*/

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module trips_core #(
    parameter CORE_ID = 0,                        // Unique core ID (0-3 in prototype)
    parameter GRID_ROWS = `GRID_ROWS,             // Default 4
    parameter GRID_COLS = `GRID_COLS,             // Default 4
    parameter FRAMES_PER_NODE = `FRAMES_PER_NODE  // Default 8 (128 total slots)
) (
    input clk,                          // Core clock
    input rst_n,                        // Active-low reset
    input morph_config_t morph_config,  // Morph config from top (D/T/S modes)
    control_if.master control_if,       // Control if (fetch/commit, morph signals)
    mem_tile_if.master mem_tile_if,       // To on-chip mem network (L2/SRF)
    output logic debug_commit,          // Debug: Block commit
    output logic [31:0] debug_pc        // Debug: Current block PC
);

    localparam TOTAL_NODES = GRID_ROWS * GRID_COLS;
    localparam BLOCK_SIZE  = `BLOCK_SIZE ;

    // Internal signals and interfaces
    // Operand network ifs (mesh for E-nodes; array per node)
    // Operand network 'verilator issue' (flattened 1D for E-nodes; rid = row*COLS + col)
    // Replaced single operand_if with flattened, directional signal arrays to resolve multi-driver errors ---
    // Signals from E-Tiles to Switching Network (Sender Path)
    operand_t   e_tile_to_net_operand [TOTAL_NODES-1:0];
    instr_num_t e_tile_to_net_dest_instr [TOTAL_NODES-1:0];
    logic [1:0] e_tile_to_net_dest_slot [TOTAL_NODES-1:0];
    logic       e_tile_to_net_req [TOTAL_NODES-1:0];
    logic       net_to_e_tile_ack [TOTAL_NODES-1:0]; // Ack from Network to E-Tile

    // Signals from Switching Network to E-Tiles (Receiver Path)
    operand_t   net_to_e_tile_operand [TOTAL_NODES-1:0];
    instr_num_t net_to_e_tile_dest_instr [TOTAL_NODES-1:0];
    logic [1:0] net_to_e_tile_dest_slot [TOTAL_NODES-1:0];
    logic       net_to_e_tile_req [TOTAL_NODES-1:0];
    logic       e_tile_to_net_ack [TOTAL_NODES-1:0]; // Ack from E-Tile to Network

    // Reg access if (E to R-banks; broadcast or per-bank)
    reg_access_if reg_if [3:0] ();           // To 4 R-banks
    // Instr fetch if (G to I-tile)
    instr_fetch_if instr_fetch_if ();
    // Mem access if (E to D-tile; multiplexed or per-column)
    mem_access_if d_mem_if ();
    // Revital broadcast wire (from morph/G to all E)
    logic revitalize_broadcast;
    // Branch/exit wires from E-grid (aggregate to G)
    logic branch_taken_wires [GRID_ROWS-1:0][GRID_COLS-1:0];
    logic [4:0] exit_id_wires [GRID_ROWS-1:0][GRID_COLS-1:0];
    logic branch_taken_agg;                 // OR all for any branch taken
    logic [4:0] exit_id_agg;                // Max or first for ID (simplified first non-zero)

    // Morph config propagation (broadcast to all sub-modules)
    // Example- frame partitions: For T-morph, divide frames/threads; S-morph enable revitalize
    logic [7:0] aframe_size_local;
    assign aframe_size_local = morph_config.aframe_size;  // Example propagation

    // Instantiate G-tile (global control)
    g_tile g_tile_inst (
        .clk(clk),                              // Clock input
        .rst_n(rst_n),                          // Reset input (active-low)
        .morph_config(morph_config),            // Morph configuration input (D/T/S modes)
        .fetch_req(control_if.fetch_req),       // Fetch request output to external (part of control_if.master)
        .block_addr(control_if.block_addr),     // Block address output for fetch 
        .commit(control_if.commit),             // Block commit input signal
        .branch_taken(branch_taken_agg),        // Branch outcome input (aggregated from E-grid)
        .block_id(control_if.block_id),         // In-flight block ID output (up to 8)
        .revitalize(revitalize_broadcast),     // Revitalization output for S-morph loops (broadcast to E)
        .instr_fetch_req(instr_fetch_if.fetch_req),   // Internal fetch request to I-tile 
        .instr_block_addr(instr_fetch_if.block_addr), // Internal block address to I-tile
        .instructions(instr_fetch_if.instructions), // Instructions input from I-tile (up to 128)
        .header(instr_fetch_if.header),         // Block header input (store mask etc)
        .ready(instr_fetch_if.ready),           // Fetch ready input from I-tile
        .debug_commit(debug_commit),            // Debug commit output
        .debug_pc(debug_pc)                     // Debug current PC output
    );

    // Instantiate 4 R-tiles (register banks)
    genvar bank_idx;
    generate
        for (bank_idx = 0; bank_idx < 4; bank_idx++) begin : gen_r_tiles
            r_tile #(
                .BANK_ID(bank_idx)
            ) r_tile_inst (
                .clk(clk),                          // Clock input
                .rst_n(rst_n),                      // Reset input
                .morph_config(morph_config),        // Morph configuration 
                .read_req(reg_if[bank_idx].read_req), // Read request input 
                .write_req(reg_if[bank_idx].write_req), // Write request input
                .reg_id(reg_if[bank_idx].reg_id),   // Reg ID input (G[0-127])
                .queue_id(reg_if[bank_idx].queue_id), // Queue ID input (R/W[0-31])
                .write_data(reg_if[bank_idx].write_data), // Write data input
                .read_data(reg_if[bank_idx].read_data), // Read data output
                .ack(reg_if[bank_idx].ack),         // Ack output
                .alignment_err(reg_if[bank_idx].alignment_err)  // Alignment error output
            );
        end
    endgenerate

    // Instantiate 4x4 E-tile grid (execution nodes)
    genvar row, col;
    generate
        for (row = 0; row < GRID_ROWS; row++) begin : gen_rows
            for (col = 0; col < GRID_COLS; col++) begin : gen_cols
                localparam int RID = row * GRID_COLS + col;
                e_tile #(
                    .ROW_ID(row),
                    .COL_ID(col),
                    .FRAMES(FRAMES_PER_NODE)
                ) e_tile_inst (
                    .clk(clk),                      // Clock input
                    .rst_n(rst_n),                  // Reset input
                    .morph_config(morph_config),    // Morph configuration (frame partitioning/revitalization)

                    // --- Connections to operand network receiver path ---
                    .operand_in(net_to_e_tile_operand[RID]), // Operand if receiver port (from network; dataflow input)
                    .dest_instr_in(net_to_e_tile_dest_instr[RID]), // Dest instr input
                    .dest_slot_in(net_to_e_tile_dest_slot[RID]), // Dest slot input (0=left,1=right,2=p)
                    .req_in(net_to_e_tile_req[RID]), // Req input
                    .ack_out(e_tile_to_net_ack[RID]), // Ack output

                    .read_req(reg_if[col % 4].read_req), // Read req output to bank (per-col bank)
                    .write_req(reg_if[col % 4].write_req), // Write req output
                    .reg_id(reg_if[col % 4].reg_id), // Reg ID output
                    .queue_id(reg_if[col % 4].queue_id), // Queue ID output
                    .write_data(reg_if[col % 4].write_data), // Write data output
                    .read_data(reg_if[col % 4].read_data), // Read data input
                    .ack_reg(reg_if[col % 4].ack), // Ack input from bank
                    .alignment_err(reg_if[col % 4].alignment_err), // Alignment err input
                    .load_req(d_mem_if.load_req), // Load req output (shared; add mux if concurrent)
                    .store_req(d_mem_if.store_req), // Store req output
                    .lsid(d_mem_if.lsid), // LSID output
                    .addr(d_mem_if.addr), // Addr output
                    .store_data(d_mem_if.store_data), // Store data output
                    .load_data(d_mem_if.load_data), // Load data input
                    .hit(d_mem_if.hit), // Hit input
                    .ack_mem(d_mem_if.ack), // Ack input from D
                    .instr_in(instr_fetch_if.instructions[(row * GRID_COLS + col) % BLOCK_SIZE]), // Instr input from I-tile (flat slice; for full 3D extend)
                    .branch_taken(branch_taken_wires[row][col]), // Branch taken output
                    .exit_id(exit_id_wires[row][col]), // EXIT_ID output

                    // --- Connections to operand network sender path ---
                    .operand_out(e_tile_to_net_operand[RID]), // Operand if sender port (to network)
                    .dest_instr_out(e_tile_to_net_dest_instr[RID]), // Dest instr output
                    .dest_slot_out(e_tile_to_net_dest_slot[RID]), // Dest slot output
                    .req_out(e_tile_to_net_req[RID]), // Req output
                    .ack_in(net_to_e_tile_ack[RID]), // Ack input from network

                    .revitalize_broadcast(revitalize_broadcast) // Add this port to e_tile module if missing; from G/morph
                );
            end
        end
    endgenerate

    // Instantiate I-tile (instruction cache and decoder)
    i_tile i_tile_inst (
        .clk(clk),                          // Clock input
        .rst_n(rst_n),                      // Reset input
        .morph_config(morph_config),        // Morph configuration (example S-morph loop prefetch)
        .fetch_req(instr_fetch_if.fetch_req), // Fetch req input from G
        .block_addr(instr_fetch_if.block_addr), // Block addr input
        .instructions(instr_fetch_if.instructions), // Instructions output (up to 128)
        .fetch_new_block(instr_fetch_if.fetch_req), // New: Drive from fetch_req (new block trigger)
        .header(instr_fetch_if.header),     // Header output (store mask etc.)
        .ready(instr_fetch_if.ready)        // Ready output to G
    );

    // Instantiate D-tile (data cache with LSID)
    d_tile d_tile_inst (
        .clk(clk),                          // Clock input
        .rst_n(rst_n),                      // Reset input
        .morph_config(morph_config),        // Morph configuration (SRF in S-morph)
        .load_req(d_mem_if.load_req),       // Load req input from E
        .store_req(d_mem_if.store_req),     // Store req input
        .lsid(d_mem_if.lsid),               // LSID input
        .addr(d_mem_if.addr),               // Addr input
        .store_data(d_mem_if.store_data),   // Store data input
        .load_data(d_mem_if.load_data),     // Load data output
        .hit(d_mem_if.hit),                 // Hit output (2-cycle latency)
        .ack(d_mem_if.ack),                 // Ack output
        .mem_tile_addr(mem_tile_if.addr),            // Addr output to on-chip net
        .mem_tile_read_req(mem_tile_if.read_req),    // Read req output
        .mem_tile_write_req(mem_tile_if.write_req),  // Write req output
        .mem_tile_wr_data_wide(mem_tile_if.wr_data_wide),  // Wide data input for SRF
        .mem_tile_config_srf(mem_tile_if.config_srf),// SRF config output
        .mem_tile_ack(mem_tile_if.ack),              // Ack input from net
        .mem_tile_rd_data_wide(mem_tile_rd_data_wide_wire)  // Wide data input for SRF
    );

    // Assign the wire for rd_data_wide
    assign mem_tile_rd_data_wide_wire = mem_tile_if.rd_data_wide;

    // Instantiate switching_network (operand mesh)
    switching_network switching_network_inst (
        .clk(clk),                          // Clock input
        .rst_n(rst_n),                      // Reset input
        .morph_config(morph_config),        // Morph configuration (unchanged, but for future extensions)
        //Connect to flattened signal arrays matching a standard network interface ---
        // Inputs to network (from E-Tiles)
        .in_operand(e_tile_to_net_operand),         // Operand array input (dataflow routing)
        .in_dest_instr(e_tile_to_net_dest_instr),   // Dest instr array
        .in_dest_slot(e_tile_to_net_dest_slot),     // Dest slot array (0/1/p)
        .in_req(e_tile_to_net_req),                 // Req array
        .in_ack(e_tile_to_net_ack),                 // Ack array from E-Tiles

        // Outputs from network (to E-Tiles)
        .out_operand(net_to_e_tile_operand),
        .out_dest_instr(net_to_e_tile_dest_instr),
        .out_dest_slot(net_to_e_tile_dest_slot),
        .out_req(net_to_e_tile_req),
        .out_ack(net_to_e_tile_ack)                 // Ack array to E-Tiles
    );

    // Aggregate branch_taken/exit_id from E-grid to G (simplified OR for taken, first non-zero for ID)
    always_comb begin
        branch_taken_agg = '0;
        exit_id_agg = '0;
        for (int r = 0; r < GRID_ROWS; r++) begin
            for (int c = 0; c < GRID_COLS; c++) begin
                branch_taken_agg |= branch_taken_wires[r][c];
                if (exit_id_wires[r][c] != 0) exit_id_agg = exit_id_wires[r][c];  // First non-zero (real: Per-block single branch)
            end
        end
    end
  
  //Commented
  //?  // TODO- Dummy placeholder - morph-specific frame mgmt etc
  //?  // Internal signal: Revitalize broadcast from morph_config/G
  //?  logic revitalize_broadcast;
  //?  always_comb revitalize_broadcast = morph_config.revitalize_enable && (morph_config.morph_mode == `MORPH_S) && control_if.commit;  // Trigger on commit in S-morph
  //?  
  //?  // Example: Frame and queue reset logic for all e_tiles and r_tiles
  //?  integer i, j;
  //?  always_ff @(posedge clk or negedge rst_n) begin
  //?      if (!rst_n) begin
  //?          // Reset reservation stations in all E-nodes
  //?          for (i = 0; i < GRID_ROWS; i = i + 1) begin
  //?              for (j = 0; j < GRID_COLS; j = j + 1) begin
  //?                  e_tile_inst[i][j].res_station_inst.reset_frames();
  //?              end
  //?          end
  //?          // Reset R-bank queues
  //?          for (i = 0; i < 4; i = i + 1) begin
  //?              r_tile_inst[i].reset_queues();
  //?          end
  //?      end else begin
  //?          // Morph handling: S-morph 'revitalize' signal
  //?          if (revitalize_broadcast) begin
  //?              for (i = 0; i < GRID_ROWS; i = i + 1) begin
  //?                  for (j = 0; j < GRID_COLS; j = j + 1) begin
  //?                      // Signal reservation station to revitalize (preserve constants)
  //?                      e_tile_inst[i][j].res_station_inst.revitalize();
  //?                  end
  //?              end
  //?          end
  //?          // (Optional) Per-morph handling, example, frame partitioning for T-morph, additional config for D-morph.
  //?      end
  //?  end

endmodule: trips_core
