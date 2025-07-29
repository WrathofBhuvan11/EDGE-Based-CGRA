// predicate_handler.sv
// Predicate check: _t/_f on pred_operand (true if LSB=1 && en && cond match).
// Hierarchy: Sub of reservation_station.
// -Pred _t/_f suffixes, p slot LSB=1 true)
// -Pred for hyperblock paths).

module predicate_handler (
    input logic predicate_en,               // Enable if _t/_f
    input logic predicate_true,             // 1=_t (true if pred true), 0=_f (true if pred false)
    input operand_t pred_operand,           // Pred operand (LSB=1 true)
    output logic pred_valid                 // True if condition met
);

    // Combo check: Valid if en && (true ? pred.data[0] : !pred.data[0])
    always_comb begin
        pred_valid = predicate_en ? (predicate_true ? pred_operand.data[0] : !pred_operand.data[0]) : 1;  // Default true if no pred
    end

endmodule
