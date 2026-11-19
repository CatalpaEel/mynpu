// Minimal DOT9 compute unit. No addresses, queue, shape, window or partial array.
module npu_cnn (
  input logic clk_i,
  rst_ni,
  flush_i,
  valid_i,
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
  npu_cnn_mac i_mac (.*);
endmodule
