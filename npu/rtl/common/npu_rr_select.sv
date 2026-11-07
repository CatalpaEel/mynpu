// Stateless round-robin selection. first_i names the first eligible index.
// The caller advances first_i only after service. No modulus, rotated dynamic
// array indexing or wide payload selection is part of the arbitration logic.
module npu_rr_select #(
  parameter int N = 8,
  IW = N > 1 ? $clog2(N) : 1
) (
  input logic [N-1:0] req_i,
  input logic [IW-1:0] first_i,
  output logic [N-1:0] grant_o,
  output logic valid_o,
  output logic [IW-1:0] index_o
);
  logic [N-1:0] masked, candidates;
  for (genvar p = 0; p < N; p++) assign masked[p] = req_i[p] && IW'(p) >= first_i;
  assign candidates = |masked ? masked : req_i;
  // Isolate the lowest set bit; all arithmetic is exactly N bits wide.
  assign grant_o = candidates & (~candidates + N'(1));
  assign valid_o = |req_i;
  always_comb begin
    index_o = 0;
    for (int p = 0; p < N; p++) index_o |= IW'(p) & {IW{grant_o[p]}};
  end
endmodule
