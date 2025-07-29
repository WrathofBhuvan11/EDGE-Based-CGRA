// trips_interfaces.svh
// Interface definitions for TRIPS tiles/networks (operand routing with targets/slots, mem with LSID, control for morphs)

`ifndef TRIPS_INTERFACES_SVH
`define TRIPS_INTERFACES_SVH

`include "trips_defines.svh"
`include "trips_types.svh"

// Operand routing if (E-nodes via network; supports targets/slots/p)
interface operand_if;
    operand_t operand;              // Operand data/metadata
    instr_num_t dest_instr;         // Destination instr num
    logic [1:0] dest_slot;          // Slot: left/right/p
    logic req;                      // Request
    logic ack;                      // Acknowledge

    modport sender (output operand, output dest_instr, output dest_slot, output req, input ack);
    modport receiver (input operand, input dest_instr, input dest_slot, input req, output ack);
endinterface

// Control signals if (G-tile to others; fetch/commit, morph config)
interface control_if;
    logic fetch_req;                // Fetch new block
    logic [31:0] block_addr;        // Block address
    logic commit;                   // Block completion
    logic branch_taken;             // Branch outcome
    logic [(`MAX_INFLIGHT_BLOCKS-1):0] block_id;  // In-flight block ID
    logic [1:0] morph_mode;         // Set morph (D/T/S)
    logic revitalize;               // S-morph loop reset
    modport master (output fetch_req, output block_addr, output morph_mode, output revitalize, output block_id, input commit, input branch_taken);
    modport slave (input fetch_req, input block_addr, input morph_mode, input revitalize, output commit, output branch_taken);
endinterface

// Register access if (E to R-tiles; queues R/W[0-31], alignment)
interface reg_access_if;
    logic read_req;                 // Read request
    logic write_req;                // Write request
    logic [6:0] reg_id;             // G[0-127] ID (7 bits)
    logic [4:0] queue_id;           // R/W queue [0-31]
    reg_data_t write_data;          // Data to write
    reg_data_t read_data;           // Read response
    logic ack;                      // Acknowledge
    logic alignment_err;            // Bank alignment violation (mod 4)

    modport tile (output read_req, output write_req, output reg_id, output queue_id, output write_data, input read_data, input ack, input alignment_err);
    modport bank (input read_req, input write_req, input reg_id, input queue_id, input write_data, output read_data, output ack, output alignment_err);
endinterface

// Memory access if (E to D-tiles; L/S with LSID)
interface mem_access_if;
    logic load_req;                 // Load request
    logic store_req;                // Store request
    lsid_t lsid;                    // LSID for ordering
    logic [31:0] addr;              // Memory address
    reg_data_t store_data;          // Data to store
    reg_data_t load_data;           // Loaded data
    logic hit;                      // Cache hit
    logic ack;                      // Acknowledge

    modport tile (output load_req, output store_req, output lsid, output addr, output store_data, input load_data, input hit, input ack);
    modport cache (input load_req, input store_req, input lsid, input addr, input store_data, output load_data, output hit, output ack);
endinterface

// Instruction fetch if (G to I-tile; hyperblock with classes)
interface instr_fetch_if;
    logic fetch_req;                // Fetch request
    logic [31:0] block_addr;        // Block address
    instr_t [(`BLOCK_SIZE-1):0] instructions;  // Fetched instructions (up to 128)
    block_header_t header;          // Block header (store mask etc.)
    logic ready;                    // Fetch complete

    modport g_tile (output fetch_req, output block_addr, input instructions, input header, input ready);
    modport i_tile (input fetch_req, input block_addr, output instructions, output header, output ready);
endinterface


// On-chip mem network if (to tiles; polymorph cache/SRF)
interface mem_tile_if;
    logic [31:0] addr;              // Tile address
    logic read_req;                 // Read
    logic write_req;                // Write
    reg_data_t [7:0] wr_data_wide;  // Wide data for SRF writes (256-bit; 8x32-bit reg_data_t)
    reg_data_t [7:0] rd_data_wide;  // Wide data for SRF reads (output from slave) - new for bidir fix
    logic data_wide_valid;          // valid flag for wide transfers (multi-flit/SRF)
    reg_data_t store_data;          // std store data for non-wide (L/S ops)
    logic config_srf;               // Config as SRF (no tags, direct access)
    logic ack;                      // Acknowledge

    modport master (output addr, output read_req, output write_req, output wr_data_wide, output data_wide_valid, output store_data, output config_srf, input rd_data_wide, input ack);
    modport slave (input addr, input read_req, input write_req, input wr_data_wide, input data_wide_valid, input store_data, input config_srf, output rd_data_wide, output ack);
endinterface

// Router interface with generic_flit_t
interface router_if;
    generic_flit_t flit_in;
    logic req_in;
    logic ack_out;
    generic_flit_t flit_out;
    logic req_out;
    logic ack_in;

    modport north (input flit_in, input req_in, output ack_out, output flit_out, output req_out, input ack_in);
    modport south (input flit_in, input req_in, output ack_out, output flit_out, output req_out, input ack_in);
    modport east (input flit_in, input req_in, output ack_out, output flit_out, output req_out, input ack_in);
    modport west (input flit_in, input req_in, output ack_out, output flit_out, output req_out, input ack_in);
    modport iolocal (input flit_in, input req_in, output ack_out, output flit_out, output req_out, input ack_in);
endinterface

`endif // TRIPS_INTERFACES_SVH
