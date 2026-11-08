`timescale 1ns / 1ps
// Quant sampling and write completion are distinct software-visible boundaries.
module tb_quant_sync;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic csr_req_i = 0, csr_we_i = 0;
  logic [7:0] csr_addr_i = 0;
  logic [31:0] csr_wdata_i = 0, csr_rdata_o;
  logic csr_error_o;
  logic [1:0] flush_i = 0, valid_i = 0, ready_o, valid_o, ready_i = 0;
  logic [1:0][31:0] data_i = 0, data_o, dst_o;
  logic [1:0] enable_o, pack_o;
  logic [1:0][1:0] written_i = 0, write_fault_i = 0;
  int checks = 0;
  npu_shared_quant dut (.*);
  task automatic wr(input int a, v);
    @(negedge clk_i);
    csr_req_i = 1;
    csr_we_i = 1;
    csr_addr_i = 8'(a);
    csr_wdata_i = 32'(v);
    #1;
    if (csr_error_o) $fatal(1, "quant config error %h", a);
    @(negedge clk_i);
    csr_req_i = 0;
    csr_we_i = 0;
  endtask
  task automatic check(input int a, v);
    csr_addr_i = 8'(a);
    #1;
    if (csr_error_o || csr_rdata_o !== 32'(v))
      $fatal(1, "quant-sync %h got=%h expected=%h err=%b", a, csr_rdata_o, v, csr_error_o);
    checks++;
  endtask
  task automatic configure(input int source);
    int base;
    base = source * 64;
    wr(base + 4, 3);
    wr(base + 8, 0);
    wr(base + 12, 0);
    wr(base + 16, 0);
    wr(base + 20, 0);
    wr(base + 24, 127);
    wr(base + 32, 'h80001800);
    wr(base, 1);
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    configure(0);
    configure(1);
    valid_i = 3;
    data_i[0] = 7;
    data_i[1] = 11;
    // Initial round-robin chooses CNN, samples once while source remains valid.
    repeat (5) @(negedge clk_i);
    check('h24, 1);
    check('h64, 0);
    check('h28, 0);
    check('h2c, 0);
    if (valid_o !== 1 || data_o[0] !== 21 || ready_o !== 0)
      $fatal(1, "quant output stall semantics");
    checks++;
    wr(4, 9);  // New arithmetic parameters cannot change already sampled result.
    repeat (8) @(negedge clk_i);
    check('h24, 1);
    if (data_o[0] !== 21) $fatal(1, "sampled quant result changed");
    ready_i[0] = 1;
    @(negedge clk_i);
    valid_i[0] = 0;
    ready_i[0] = 0;
    check('h28, 1);
    check('h2c, 0);  // Request issued; ACK still absent.
    repeat (4) @(negedge clk_i);
    check('h64, 1);
    check('h68, 0);
    if (data_o[1] !== 33) $fatal(1, "Matrix quant result");
    // CNN two ACK channels can finish together; do not merge their counts.
    written_i[0] = 2;
    @(negedge clk_i);
    written_i = 0;
    check('h2c, 2);
    // Flush only the in-flight Matrix sample, never count an issued result.
    flush_i[1] = 1;
    @(negedge clk_i);
    valid_i[1] = 0;
    flush_i = 0;
    check('h64, 1);
    check('h68, 0);
    check('h74, 1);
    valid_i[1] = 1;
    repeat (4) @(negedge clk_i);
    ready_i[1] = 1;
    @(negedge clk_i);
    valid_i = 0;
    ready_i = 0;
    check('h64, 2);
    check('h68, 1);
    check('h6c, 0);
    write_fault_i[1] = 1;
    @(negedge clk_i);
    write_fault_i = 0;
    check('h70, 1);
    check('h6c, 0);
    // Counters are unsigned modulo 2^32. Deposit near wrap instead of 2^32 clocks.
    force dut.written = 64'h00000000ffffffff;
    #1;
    release dut.written;
    written_i[0] = 1;
    @(negedge clk_i);
    written_i = 0;
    check('h2c, 0);
    rst_ni = 0;
    @(negedge clk_i);
    rst_ni = 1;
    check('h24, 0);
    check('h28, 0);
    check('h2c, 0);
    check('h64, 0);
    check('h70, 0);
    check('h74, 0);
    $display(
        "QUANT SYNC PASS checks=%0d sampling/round-robin/stalls/issued-vs-ACK/two-ACKs/flush/error/wrap/reset",
        checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "quant-sync timeout");
  end
endmodule
