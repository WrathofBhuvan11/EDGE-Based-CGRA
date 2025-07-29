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

    // Raw instruction buffer for the block (fetched from cache_ram)
    logic [31:0] raw_instructions [(`BLOCK_SIZE-1):0];

    // Fetch logic: On req, "load" block from ram (sim: generate dummy instr/header)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready <= 0;
            for (int i = 0; i < `BLOCK_SIZE; i++) begin
                raw_instructions[i] = '0;
            end
            header <= '0;
            lsid_counter <= 0;
            exit_id_counter <= 0;
        end else if (fetch_req) begin
            // Simulate fetch (1-cycle hit; real cache lookup/tag check)
            cache_hit <= 1;  // Assume hit
            if (cache_hit) begin
                // "Load" raw_instructions from cache_ram (real read: interleaved banks)
                for (int i = 0; i < `BLOCK_SIZE; i++) begin
                    int bank = i % 5;  // Interleave across 5 banks (4 rows +1 reg)
                    int offset = (block_addr[10:0] + i * 4) % BANK_SIZE;  // Word-aligned (32-bit=4B), mod bank size (simplified direct; real set_idx + line_off)
                    raw_instructions[i] = {cache_ram[bank][offset+3], cache_ram[bank][offset+2], cache_ram[bank][offset+1], cache_ram[bank][offset]};  // Big-endian byte pack to 32-bit word
                end
                // Header gen (simplified fixed; real from compiler mask/reg count)
                header.store_mask <= 32'hFFFFFFFF;  // Example all 32 stores expected
                header.num_reg_writes <= 'd32;      // Max 32
                header.block_valid <= 1;
                header.morph_mode <= morph_config.morph_mode;  // Prop morph
                ready <= 1;
            end else begin
                ready <= 0;  // Miss stall (real: Request L2)
            end
        end else begin
            ready <= 0;
        end
    end

    // Decode: fill instructions array from raw_instructions
    always_comb begin
        for (int i = 0; i < `BLOCK_SIZE; i++) begin
            instructions[i] = decode_instr(raw_instructions[i]);  // Call function for each
            // Auto LSID/EXIT_ID if 0 (in function combo; counters ff)
        end
    end

    //Instruction decoder: Parses raw 32-bit word to instr_t (class/opcode/targets/slot/pred/LSID/imms/%bit).
    // Assumes bit layout (inferred: [31:29 res, 29 pred_en, 27 pred_true, 26:24 class, 23:19 lsid/exit, 18:0 imm/bit; targets packed in imm for G).
    // Decode function (combo; parse raw to instr_t with auto LSID/EXIT_ID)
    function automatic instr_t decode_instr(input logic [31:0] raw_instr);
        instr_t dec;
        // Assumed layout (inferred; adjust per full spec): [31:29 res][28 pred_en][27 pred_true][26:24 class][23:19 lsid/exit][18:0 imm/bit/op subset]
        dec.opcode = raw_instr[7:0];  // Low 8 for opcode
        dec.isa_class = raw_instr[26:24];  // Class 3-bit
        dec.predicate_en = raw_instr[28];  // Pred en
        dec.predicate_true = raw_instr[27];  // _t=1, _f=0
        dec.lsid = raw_instr[23:19];       // LSID 5-bit
        dec.exit_id = raw_instr[23:19];    // EXIT_ID (shared field for B)
        dec.imm_value = raw_instr[19:0];   // Imm 20-bit max
        dec.bit_extract = raw_instr[21:20];  // bit 2-bit for C
        // Targets: Assumed packed in imm for G (real separate fields/encoding)
        dec.targets[0].target_instr = raw_instr[15:8];  // Target0 num
        dec.targets[0].slot = raw_instr[1:0];    // Slot
        dec.targets[0].valid = 1;                       // Assume valid if non-zero
        dec.targets[1].target_instr = raw_instr[23:16]; // Target1 (example overlap; adjust)
        dec.targets[1].slot = raw_instr[3:2];
        dec.targets[1].valid = raw_instr[23:16] != 0;

        // Auto LSID/EXIT_ID if 0 (increment counters)
        if (dec.isa_class inside {`CLASS_L, `CLASS_S} && dec.lsid == 0) begin
            dec.lsid = lsid_counter;
        end
        if (dec.isa_class == `CLASS_B && dec.exit_id == 0) begin
            dec.exit_id = exit_id_counter;
        end
        return dec;
    endfunction

    // Morph handling: Unused base (future S-morph loop prefetch if revitalize)

endmodule
