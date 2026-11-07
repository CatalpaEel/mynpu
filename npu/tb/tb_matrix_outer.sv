`timescale 1ns / 1ps
module tb_matrix_outer;
  logic clk_i = 0, rst_ni = 0, flush_i = 0, valid_i = 0, multiply_i = 0, emit_i = 0, ready_i = 0;
  always #10 clk_i = ~clk_i;
  logic [3:0] row_mask_i = 0, col_mask_i = 0, index_i = 0;
  logic signed [3:0][15:0] a_i = 0, b_i = 0;
  logic [31:0] addend_i = 0;
  wire ready_o, valid_o;
  wire [31:0] data_o;
  npu_matmul dut (.*);
  logic [31:0] reference[16];
  logic [3:0] ref_index = 0;
  bit ref_valid = 0;
  int checks = 0, macs = 0, stalls = 0;
  always @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      for (int cell_index = 0; cell_index < 16; cell_index++) reference[cell_index] = 0;
      ref_index = 0;
      ref_valid = 0;
    end else if (ready_o) begin
      ref_valid = valid_i && emit_i;
      if (valid_i) begin
        if (emit_i) ref_index = index_i;
        if (multiply_i) begin
          for (int r = 0; r < 4; r++)
          for (int c = 0; c < 4; c++)
          if (row_mask_i[r] && col_mask_i[c]) begin
            reference[4*r+c] += 32'(longint'($signed(a_i[r])) * longint'($signed(b_i[c])));
            macs++;
          end
        end else reference[index_i] += addend_i;
      end
    end else if (valid_o && !ready_i) stalls++;
    #1;
    if (valid_o !== ref_valid || data_o !== reference[ref_index])
      $fatal(
          1,
          "outer arithmetic/backpressure mismatch index=%0d got=%h expected=%h",
          ref_index,
          data_o,
          reference[ref_index]
      );
    checks++;
  end
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int t = 0; t < 6000; t++) begin
      @(negedge clk_i);
      flush_i = t % 257 == 0;
      valid_i = $urandom_range(0, 3) != 0;
      ready_i = t % 32 >= 8;
      multiply_i = t % 5 != 0;
      emit_i = t % 3 == 0;
      row_mask_i = 4'($urandom);
      col_mask_i = 4'($urandom);
      index_i = 4'($urandom);
      addend_i = $urandom;
      for (int l = 0; l < 4; l++) begin
        a_i[l] = t % 7 == 0 ? -32768 : 16'($urandom);
        b_i[l] = t % 7 == 0 ? -32768 : 16'($urandom);
      end
    end
    @(negedge clk_i);
    flush_i = 0;
    valid_i = 1;
    ready_i = 1;
    multiply_i = 0;
    emit_i = 1;
    addend_i = 0;
    for (int i = 0; i < 16; i++) begin
      index_i = 4'(i);
      @(negedge clk_i);
    end
    if (macs < 5000 || stalls < 100) $fatal(1, "insufficient outer coverage");
    $display(
        "MATRIX OUTER PASS checks=%0d macs=%0d stalls=%0d 16-accumulators/masks/INT16-wrap/seeds/emit/flush",
        checks, macs, stalls);
    $finish;
  end
endmodule
