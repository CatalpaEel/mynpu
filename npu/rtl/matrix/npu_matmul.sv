// Pure 4x4 outer-product engine: C[r,c] += A[r]*B[c], modulo INT32.
// Masks disable tail rows/columns. Non-multiply operations add one INT32 seed
// to index_i, and emit optionally exposes that cell through ready/valid.
// Tile loops, operand staging and addresses belong to npu_matrix_stream.
module npu_matmul (
  input logic clk_i,
  rst_ni,
  flush_i,
  valid_i,
  output logic ready_o,
  input logic multiply_i,
  emit_i,
  input logic [3:0] row_mask_i,
  col_mask_i,
  index_i,
  input logic signed [3:0][15:0] a_i,
  b_i,
  input logic [31:0] addend_i,
  output logic valid_o,
  input logic ready_i,
  output logic [31:0] data_o
);
  logic [31:0] accumulator[16];
  logic [3:0] output_index;
  assign ready_o = rst_ni && !flush_i && (!valid_o || ready_i);
  assign data_o = accumulator[output_index];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int slot = 0; slot < 16; slot++) accumulator[slot] <= 0;
      valid_o <= 0;
      output_index <= 0;
    end else if (flush_i) begin
      for (int slot = 0; slot < 16; slot++) accumulator[slot] <= 0;
      valid_o <= 0;
      output_index <= 0;
    end else if (ready_o) begin
      valid_o <= valid_i && emit_i;
      if (valid_i) begin
        if (emit_i) output_index <= index_i;
        // Select the addend before each accumulator's single adder. A dynamic
        // indexed seed update otherwise infers a second accumulator read tree.
        for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++) begin
          logic [31:0] delta;
          delta = multiply_i ? 32'($signed(a_i[r]) * $signed(b_i[c])) : addend_i;
          if (multiply_i ? row_mask_i[r] && col_mask_i[c] : index_i == 4'(4 * r + c))
            accumulator[4*r+c] <= accumulator[4*r+c] + delta;
        end
      end
    end
  end
endmodule
