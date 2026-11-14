// Arithmetic only. clear/load/accumulate apply to an accepted operation.
// offset is an arithmetic operand, not a shape or quantization descriptor.
// Signed 9-bit subtraction and the INT32 accumulator use modular arithmetic.
module npu_cnn_mac (
  input logic clk_i,
  rst_ni,
  flush_i,
  input logic valid_i,
  output logic ready_o,
  input logic signed [8:0] a_i[9],
  offset_i,
  input logic signed [7:0] w_i[9],
  input logic [8:0] mask_i,
  input logic clear_i,
  load_i,
  emit_i,
  input logic [31:0] seed_i,
  output logic valid_o,
  input logic ready_i,
  output logic [31:0] data_o
);
  logic [31:0] accumulator;
  logic signed [19:0] dot;
  logic [31:0] result;
  always_comb begin
    dot = 0;
    for (int t = 0; t < 9; t++) begin
      logic signed [8:0] centered;
      logic signed [16:0] product;
      centered = a_i[t] - offset_i;
      product = centered * w_i[t];
      if (mask_i[t]) dot = dot + 20'(product);
    end
    result = (load_i ? seed_i : clear_i ? 32'b0 : accumulator) + 32'(dot);
  end
  assign ready_o = rst_ni && !flush_i && (!valid_o || ready_i);
  assign data_o = accumulator;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      accumulator <= 0;
      valid_o <= 0;
    end else if (flush_i) begin
      accumulator <= 0;
      valid_o <= 0;
    end else if (ready_o) begin
      valid_o <= valid_i && emit_i;
      if (valid_i) accumulator <= result;
    end
endmodule
