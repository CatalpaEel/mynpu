`timescale 1ns / 1ps
// Compare aperture-sized arithmetic to the original full-width contract.
module tb_address_ranges;
  import npu_addr_pkg::*;
  int checks = 0;
  function automatic bit reference_ok(input logic [31:0] base, bytes);
    logic [32:0] ending;
    ending = {1'b0, base} + {1'b0, bytes};
    return bytes != 0 && (is_stream_address(
        base
    ) || ((base[31:14] == 18'h20000 && ending <= {1'b0, RF_BASE}) || (is_rf_address(
        base
    ) && ending <= {1'b0, RF_BASE} + RF_BYTES)));
  endfunction
  task automatic check(input logic [31:0] base, bytes);
    if (data_range_ok(base, bytes) !== reference_ok(base, bytes))
      $fatal(1, "range mismatch base=%h bytes=%h", base, bytes);
    checks++;
  endtask
  initial begin
    logic [31:0] a, n;
    // Every byte start in the aperture, including both sides of each target.
    for (int offset = -16; offset < 65552; offset++) begin
      a = 32'h80000000 + offset;
      check(a, 0);
      check(a, 1);
      check(a, 4);
      check(a, 16384);
      check(a, RF_BYTES);
      check(a, RF_BYTES + 1);
      check(a, 32'h80004000 - a);
      check(a, 32'h80004001 - a);
      check(a, RF_BASE + RF_BYTES - a);
      check(a, RF_BASE + RF_BYTES + 1 - a);
      check(a, 'hffffffff);
      check(a, 'h80000000);
    end
    for (int trial = 0; trial < 200000; trial++) begin
      a = trial[0] ? $urandom : 32'h80000000 | ($urandom & 'hffff);
      n = trial[1] ? $urandom : $urandom & 'h1ffff;
      check(a, n);
    end
    $display("ADDRESS RANGES PASS checks=%0d RF_BYTES=%0d", checks, RF_BYTES);
    $finish;
  end
endmodule
