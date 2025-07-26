// i_tile.sv
// Instruction cache tile: Banked 6KB (1 bank/row +1 for regs), fetches/decodes hyperblocks to instr_t array (classes G/I/L/S/B/C, _t/_f pred, LSID/EXIT_ID auto if missing, %bit for C, sequence nums).
// Outputs instructions[128] distributed to E-grid, header (store_mask/reg_writes) to G for termination.
// Hierarchy: Contains isa_decoder (parse classes/opcodes/targets/imms/LSID/bit/pred).
`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module i_tile (
    input clk,                              // Clock input
    input rst_n,                            // Reset input (active-low)
    input morph_config_t morph_config,      // Morph configuration (future S-morph loop prefetch)
    input logic fetch_req,                  // Fetch req input from G (instr_fetch_if.slave)
    input logic [31:0] block_addr,          // Block addr input
    output instr_t [(`BLOCK_SIZE-1):0] instructions,  // Instructions output (up to 128 to E-grid)
    output block_header_t header,           // Header output (store_mask/reg_writes to G)
    input logic fetch_new_block,            // Input from G (for decoder reset)
    output logic ready                      // Ready output (fetch/decode complete)
);

    // Internal cache: Simplified RAM (6KB total; banked 5x1.2KB, direct-mapped for sim)
    localparam BANK_SIZE = 1228;            // ~1.2KB/bank (6144/5; adjust for assoc)
    logic [7:0] cache_ram [4:0] [BANK_SIZE-1:0];  // 5 banks (4 rows +1 reg)
    logic cache_hit;                        // Hit flag (simplified all hit for sim)
    logic [31:0] lsid_counter, exit_id_counter;  // Auto counters for LSID/EXIT_ID if missing

    // Fetch logic: On req, "load" block from ram (sim: generate dummy instr/header)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready <= 0;
            instructions <= '0;
            header <= '0;
            lsid_counter <= 0;
            exit_id_counter <= 0;
        end else if (fetch_req) begin
            // Simulate fetch (1-cycle hit; real cache lookup/tag check)
            cache_hit = 1;  // Assume hit
            if (cache_hit) begin
                // "Decode" to instructions (simplified: Fill with NOP; real parse TASL binary)
                for (int i = 0; i < `BLOCK_SIZE; i++) begin
                    instructions[i].opcode = `OP_NOP;
                    // Auto LSID/EXIT_ID if 0 
                    if (instructions[i].isa_class inside {`CLASS_L, `CLASS_S} && instructions[i].lsid == 0) instructions[i].lsid = lsid_counter++;
                    if (instructions[i].isa_class == `CLASS_B && instructions[i].exit_id == 0) instructions[i].exit_id = exit_id_counter++;
                end
                // Header gen (simplified fixed; real from compiler mask/reg count)
                header.store_mask = 32'hFFFFFFFF;  // Example all 32 stores expected
                header.num_reg_writes = 'd32;      // Max 32
                header.block_valid = 1;
                header.morph_mode = morph_config.morph_mode;  // Prop morph
                ready = 1;
            end else ready = 0;  // Miss stall (real: Request L2)
        end else ready = 0;
    end

    // Instantiate isa_decoder (parse to instr_t; but since fetch "decodes", stub or integrate)
    isa_decoder isa_decoder_inst (
        .clk(clk),
        .rst_n(rst_n),
        .raw_instr(32'h0),                      // Raw from cache (simplified dummy; real byte_ram read)
        .fetch_new_block(fetch_new_block),      // new block signal from G
        .decoded_instr(instructions[0])         // Output example (full array in loop above)
    );

    // Morph handling: Unused base (future S-morph loop prefetch if revitalize)

endmodule
