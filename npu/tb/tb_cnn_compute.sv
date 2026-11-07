`timescale 1ns / 1ps
module tb_cnn_compute;
  logic clk_i = 0, rst_ni = 0, flush_i = 0, valid_i = 0, ready_i = 0;
  always #10 clk_i = ~clk_i;
  wire ready_o, valid_o;
  logic signed [8:0] a_i[9], offset_i = 0;
  logic signed [7:0] w_i[9];
  logic [8:0] mask_i = 0;
  logic clear_i = 0, load_i = 0, emit_i = 0;
  logic [31:0] seed_i = 0;
  wire [31:0] data_o;
  npu_cnn dut (.*);
  logic [31:0] reference_acc = 0;
  bit reference_valid = 0;
  int checks = 0, accepted = 0, emitted = 0, stalls = 0;
  always @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      reference_acc = 0;
      reference_valid = 0;
    end else begin
      if (valid_o && ready_i) emitted++;
      if (valid_o && !ready_i) stalls++;
      if (ready_o) begin
        reference_valid = valid_i && emit_i;
        if (valid_i) begin
          longint signed dot;
          dot = 0;
          for (int t = 0; t < 9; t++) begin
            logic signed [8:0] centered;
            centered = 9'(int'(a_i[t]) - int'(offset_i));
            if (mask_i[t]) dot += longint'(centered) * longint'(w_i[t]);
          end
          reference_acc = (load_i ? seed_i : clear_i ? 32'b0 : reference_acc) + 32'(dot);
          accepted++;
        end
      end
    end
    #1;
    if (valid_o !== reference_valid || data_o !== reference_acc)
      $fatal(1, "DOT9 handshake/arithmetic mismatch got=%h expected=%h", data_o, reference_acc);
    checks++;
  end
  initial begin
    for (int t = 0; t < 9; t++) begin
      a_i[t] = 0;
      w_i[t] = 0;
    end
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int n = 0; n < 2000; n++) begin
      @(negedge clk_i);
      flush_i = n % 137 == 0;
      valid_i = $urandom_range(0, 3) != 0;
      ready_i = (n % 32 < 8) ? 0 : $urandom_range(0, 3) != 0;
      clear_i = n % 13 == 0;
      load_i = n % 7 == 0;
      emit_i = n % 5 != 0;
      mask_i = 9'($urandom);
      seed_i = $urandom;
      offset_i = 9'($urandom);
      for (int t = 0; t < 9; t++) begin
        a_i[t] = 9'($urandom);
        w_i[t] = 8'($urandom);
      end
    end
    @(negedge clk_i);
    valid_i = 0;
    ready_i = 1;
    flush_i = 0;
    repeat (3) @(negedge clk_i);
    if (accepted < 500 || emitted < 300 || stalls < 100) $fatal(1, "Insufficient compute coverage");
    $display(
        "CNN COMPUTE PASS checks=%0d accepted=%0d emitted=%0d stalls=%0d clear/load/accumulate/emit/masks/offset/modulo32/flush",
        checks, accepted, emitted, stalls);
    $finish;
  end
endmodule
