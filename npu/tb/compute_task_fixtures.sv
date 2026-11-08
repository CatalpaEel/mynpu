// Test-only task-level adapters. Not part of synthesizable source lists.
module matrix_task_fixture (
  input logic clk_i,
  rst_ni,
  start_i,
  input logic [31:0] a_i,
  b_i,
  d_i,
  input logic [4:0] m_i,
  n_i,
  flags_i,
  input logic [8:0] k_i,
  output logic busy_o,
  done_o,
  fault_o,
  req_o,
  we_o,
  output logic [31:0] addr_o,
  wdata_o,
  input logic gnt_i,
  rvalid_i,
  error_i,
  input logic [31:0] rdata_i
);
  logic matrix_compute_valid, matrix_compute_ready, matrix_compute_flush;
  logic matrix_compute_multiply, matrix_compute_emit, matrix_result_valid, matrix_result_ready;
  logic signed [3:0][15:0] matrix_compute_a, matrix_compute_b;
  logic [31:0] matrix_compute_addend, matrix_result_data;
  logic [3:0] matrix_rows, matrix_cols, matrix_index;
  npu_matmul i_matmul (
    .row_mask_i(matrix_rows),
    .col_mask_i(matrix_cols),
    .index_i   (matrix_index),
    .clk_i,
    .rst_ni    (rst_ni),
    .flush_i   (matrix_compute_flush),
    .valid_i   (matrix_compute_valid),
    .ready_o   (matrix_compute_ready),
    .multiply_i(matrix_compute_multiply),
    .emit_i    (matrix_compute_emit),
    .a_i       (matrix_compute_a),
    .b_i       (matrix_compute_b),
    .addend_i  (matrix_compute_addend),
    .valid_o   (matrix_result_valid),
    .ready_i   (matrix_result_ready),
    .data_o    (matrix_result_data)
  );
  npu_matrix_stream i_stream (
    .observe_o             (),
    .quant_written_o       (),
    .quant_write_fault_o   (),
    .quant_enable_i        (1'b0),
    .quant_pack_i          (1'b0),
    .quant_dst_i           (32'b0),
    .be_o                  (),
    .compute_row_mask_o    (matrix_rows),
    .compute_col_mask_o    (matrix_cols),
    .compute_index_o       (matrix_index),
    .precision_i           (flags_i[4]),
    .element_log2_i        (flags_i[3] ? (flags_i[4] ? 2'd1 : 2'd0) : 2'd2),
    .flags_i               ({2'b0, flags_i[2:0]}),
    .lda_i                 (16'b0),
    .ldb_i                 (16'b0),
    .compute_valid_o       (matrix_compute_valid),
    .compute_ready_i       (matrix_compute_ready),
    .compute_flush_o       (matrix_compute_flush),
    .compute_multiply_o    (matrix_compute_multiply),
    .compute_emit_o        (matrix_compute_emit),
    .compute_a_o           (matrix_compute_a),
    .compute_b_o           (matrix_compute_b),
    .compute_addend_o      (matrix_compute_addend),
    .compute_result_valid_i(matrix_result_valid),
    .compute_result_ready_o(matrix_result_ready),
    .compute_result_data_i (matrix_result_data),
    .gather_req_o          (),
    .gather_addr_o         (),
    .gather_gnt_i          (3'b0),
    .gather_valid_i        (3'b0),
    .gather_error_i        (3'b0),
    .gather_data_i         (96'b0),
    .*
  );
endmodule
module vector_task_fixture (
  input logic clk_i,
  rst_ni,
  start_i,
  input logic [31:0] a_i,
  b_i,
  d_i,
  scalar_i,
  input logic [12:0] len_i,
  input logic [8:0] op_i,
  input logic [31:0] program_cfg_i,
  input logic [15:0][31:0] program_i,
  output logic busy_o,
  done_o,
  fault_o,
  req_o,
  we_o,
  output logic [3:0] be_o,
  output logic [31:0] addr_o,
  wdata_o,
  input logic gnt_i,
  rvalid_i,
  error_i,
  input logic [31:0] rdata_i
);
  logic [4:0] vector_compute_op;
  logic signed [31:0] vector_compute_a, vector_compute_b, vector_compute_c, vector_compute_data;
  logic vector_carry_in, vector_carry_out, vector_compute_simd;
  npu_vector i_vector (
    .simd_i (vector_compute_simd),
    .op_i   (vector_compute_op),
    .a_i    (vector_compute_a),
    .b_i    (vector_compute_b),
    .c_i    (vector_compute_c),
    .carry_i(vector_carry_in),
    .carry_o(vector_carry_out),
    .data_o (vector_compute_data)
  );
  npu_vector_stream i_issue (
    .observe_o      (),
    .compute_simd_o (vector_compute_simd),
    .compute_op_o   (vector_compute_op),
    .compute_a_o    (vector_compute_a),
    .compute_b_o    (vector_compute_b),
    .compute_c_o    (vector_compute_c),
    .compute_carry_o(vector_carry_in),
    .compute_carry_i(vector_carry_out),
    .compute_data_i (vector_compute_data),
    .gather_req_o   (),
    .gather_addr_o  (),
    .gather_gnt_i   (3'b0),
    .gather_valid_i (3'b0),
    .gather_error_i (3'b0),
    .gather_data_i  (96'b0),
    .*
  );
endmodule
