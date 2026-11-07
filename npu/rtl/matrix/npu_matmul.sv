// Pure signed 16x16 MAC / INT32 add. No task, address, memory port or shape.
// INT8 values are sign-extended by the operand feeder. Accumulation wraps INT32.
// emit marks a result for ready/valid consumption; flush discards all math state.
module npu_matmul #(
  parameter bit PARALLEL = 0
) (
  input logic [2:0] extra_valid_i,
  input logic signed [2:0][15:0] extra_a_i,
  extra_b_i,
  input logic clk_i,
  rst_ni,
  flush_i,
  valid_i,
  output logic ready_o,
  input logic multiply_i,
  emit_i,
  input logic signed [15:0] a_i,
  b_i,
  input logic [31:0] addend_i,
  output logic valid_o,
  input logic ready_i,
  output logic [31:0] data_o
);
  logic [31:0] accumulator, term;
  logic [31:0] products[4];
  assign products[0] = 32'($signed(a_i) * $signed(b_i));
  for (genvar p = 0; p < 3; p++) begin : g_products
    if (PARALLEL)
      assign products[p+1] = extra_valid_i[p] ? 32'($signed(
          extra_a_i[p]
      ) * $signed(
          extra_b_i[p]
      )) : 0;
    else assign products[p+1] = 0;
  end
  assign term = multiply_i ? (products[0] + products[1]) + (products[2] + products[3]) : addend_i;
  assign data_o = accumulator;
  assign ready_o = rst_ni && !flush_i && (!valid_o || ready_i);
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      accumulator <= 0;
      valid_o <= 0;
    end else if (flush_i) begin
      accumulator <= 0;
      valid_o <= 0;
    end else if (ready_o) begin
      valid_o <= valid_i && emit_i;
      if (valid_i) accumulator <= accumulator + term;
    end
endmodule
