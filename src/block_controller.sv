// block_controller.sv
// Manages block atomicity, termination (constant outputs via header mask), speculation (flush mispredict/mis-exit), EXIT_ID branch resolution, revitalization (S-morph loops: reset stations, keep constants).
// FSM for states (IDLE/FETCH/EXEC/COMMIT/FLUSH), counters for reg_writes/stores, bitmap for inflight (up to 8), counter for S-morph iterations.
// Hierarchy: Standalone in g_tile; no sub-instances.
//  - Multiblock speculation, commit/dealloc/flush;
//  - Revitalization on commit if counter>0, preserve constants
//  - Constant outputs/store mask/LSID for termination; header encodes reg writes/stores, 
//  - EXIT_ID for branches/multiple exits; optional sequence nums

`include "includes/trips_defines.svh"
`include "includes/trips_types.svh"
`include "includes/trips_interfaces.svh"
`include "includes/trips_isa.svh"
`include "includes/trips_params.svh"
`include "includes/trips_config.svh"

module block_controller (
    input clk,                                  // Clock input
    input rst_n,                                // Reset input (active-low)
    input morph_config_t morph_config,          // Morph configuration (e.g., enable revitalize in S-morph)
    input logic commit,                         // Block commit input signal (from core/e_tiles outputs met)
    input logic branch_taken,                   // Branch outcome input (for next_addr prediction)
    input logic [4:0] exit_id,                  // EXIT_ID input from branch instr (TASL B class, multiple exits)
    input block_header_t header,                // Block header input (store_mask/num_reg_writes from I-tile)
    input logic fetch_req,                      // Added input for fetch request (from G-tile external/internal)
    input logic ready,                          // Added input for fetch ready (from I-tile)
    output logic [(`MAX_INFLIGHT_BLOCKS-1):0] inflight_blocks,  // In-flight blocks bitmap output
    output logic speculation_flush,             // Speculation flush output (on mispredict/mis-exit)
    output logic [31:0] next_block_addr        // Next predicted block addr output (for fetch)
    //output logic revitalize                     // Revitalization output (S-morph loop reset signal)
);

    // Internal signals
    logic [31:0] store_count;                   // Count received stores (match header.store_mask bits set)
    logic [4:0] reg_write_count;                // Count received reg writes (match header.num_reg_writes)
    logic branch_received;                      // Flag for one branch received (constant 1/block)
    logic block_complete;                       // All outputs met (stores + writes +1 branch)
    logic [7:0] counter;                        // S-morph iteration counter (decrement on commit)
    logic mis_exit;                             // Mispredict on wrong EXIT_ID
    logic [31:0] predicted_offset [31:0];       // Prediction table for EXIT_ID offsets (simplified array; load from config/memory)

    // FSM states for block lifecycle
    typedef enum logic [2:0] {IDLE, FETCHING, EXECUTING, COMMITTING, FLUSHING} state_t;
    state_t state, next_state;

    // Reset and state transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            inflight_blocks <= 0;
            store_count <= 0;
            reg_write_count <= 0;
            branch_received <= 0;
            counter <= 0;  // S-morph counter reset
            speculation_flush <= 0;
            //revitalize <= 0;
            next_block_addr <= 0;
            predicted_offset <= {32{32'h100}};  // Simplified default offsets; load from mem/config in real
        end else begin
            state <= next_state;
            // Update counters on events (e.g., from e/d/r tiles via signals; simplified assume inputs increment)
            if (commit) begin
                store_count <= 0;
                reg_write_count <= 0;
                branch_received <= 0;
                inflight_blocks <= inflight_blocks >> 1;  // Commit oldest
                if (morph_config.morph_mode == `MORPH_S && counter > 0) begin
                    counter <= counter - 1;
                    //revitalize <= 1;  // Trigger reset (preserve constants)
                end 
            end else if (branch_taken) begin
                branch_received <= 1;
            end
            // Increment store_count/reg_write_count on store/write signals (omitted ports; assume from d/r tiles)
        end
    end

    // Next state logic
    always_comb begin
        next_state = state;
        block_complete = (store_count == $countones(header.store_mask)) && (reg_write_count == header.num_reg_writes) && branch_received;
        mis_exit = branch_taken && (exit_id != 0);  // Simplified mis-exit detect (assume ID 0 default)
        speculation_flush = mis_exit || (branch_taken && !block_complete);  // Flush on mis or early branch

        case (state)
            IDLE: if (fetch_req) next_state = FETCHING;
            FETCHING: if (ready) begin
                next_state = EXECUTING;
                inflight_blocks <= {inflight_blocks[`MAX_INFLIGHT_BLOCKS-2:0], 1'b1};  // Add new block
                counter <= morph_config.morph_mode == `MORPH_S ? 8'd16 : 0;  // Example S-morph iterations
            end
            EXECUTING: if (block_complete) next_state = COMMITTING;
            COMMITTING: next_state = IDLE;
            FLUSHING: next_state = IDLE;  // After flush
        endcase
        if (speculation_flush) next_state = FLUSHING;
    end

    // Branch/EXIT_ID handling: Update next_addr on taken (use EXIT_ID to index predicted_offset table)
    always_comb begin
        if (branch_taken) begin
            next_block_addr <= next_block_addr + predicted_offset[exit_id];  // Offset from table (loaded/configured)
        end else begin
            next_block_addr <= next_block_addr + 32'h100;  // Default sequential (simplified)
        end
    end

    // Revitalization: Already assigned; broadcast to res stations via morph_config (in e_tile)
    // (Handled in g_tile wrapper; here just generate signal based on counter/commit)

endmodule
