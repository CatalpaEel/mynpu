`timescale 1ns / 1ps
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
  logic [1:0][3:0] written_i = 0, write_fault_i = 0, cancelled_i = 0;
  int checks = 0;
  npu_shared_quant dut (.*);
  task automatic tick;
    @(posedge clk_i);
    #1;
    @(negedge clk_i);
  endtask
  task automatic wr(input int a, v);
    csr_req_i = 1;
    csr_we_i = 1;
    csr_addr_i = 8'(a);
    csr_wdata_i = 32'(v);
    #1;
    if (csr_error_o) $fatal(1, "quant config error");
    tick();
    csr_req_i = 0;
    csr_we_i = 0;
  endtask
  task automatic check(input int a, v);
    csr_addr_i = 8'(a);
    #1;
    if (csr_error_o || csr_rdata_o !== 32'(v))
      $fatal(1, "quant-sync %h got=%h expected=%h", a, csr_rdata_o, v);
    checks++;
  endtask
  task automatic send(input int source, value);
    valid_i = 2'(1 << source);
    data_i[source] = 32'(value);
    #1;
    while (!ready_o[source]) tick();
    tick();
    valid_i = 0;
  endtask
  initial begin
    repeat (4) tick();
    rst_ni = 1;
    for (int p = 0; p < 2; p++) begin
      wr(p * 64 + 4, 3);
      wr(p * 64 + 24, 127);
      wr(p * 64 + 32, 'h80001800);
      wr(p * 64, 1);
    end
    send(0, 7);
    send(1, 11);
    repeat (4) tick();
    check('h24, 1);
    check('h64, 1);
    check('h28, 0);
    check('h2c, 0);
    if (valid_o !== 1 || data_o[0] !== 21) $fatal(1, "CNN stalled output");
    wr(4, 9);
    repeat (8) tick();
    check('h24, 1);
    if (data_o[0] !== 21) $fatal(1, "sampled arithmetic changed");
    ready_i[0] = 1;
    tick();
    ready_i = 0;
    check('h28, 1);
    check('h2c, 0);
    if (valid_o !== 2 || data_o[1] !== 33) $fatal(1, "Matrix queued owner/data");
    written_i[0] = 4;
    tick();
    written_i = 0;
    check('h2c, 4);
    flush_i[1] = 1;
    tick();
    flush_i = 0;
    check('h64, 1);
    check('h68, 0);
    check('h74, 1);
    send(1, 11);
    repeat (3) tick();
    ready_i[1] = 1;
    tick();
    ready_i = 0;
    check('h64, 2);
    check('h68, 1);
    check('h6c, 0);
    write_fault_i[1] = 3;
    cancelled_i[1] = 2;
    tick();
    write_fault_i = 0;
    cancelled_i = 0;
    check('h70, 3);
    check('h7c, 2);
    // Eight samples in consecutive cycles: arithmetic initiation interval is 1.
    ready_i = 3;
    for (int n = 0; n < 8; n++) begin
      valid_i = 1;
      data_i[0] = 32'(n);
      #1;
      if (!ready_o[0]) $fatal(1, "quant pipeline inserted a bubble");
      tick();
    end
    valid_i = 0;
    repeat (4) tick();
    ready_i = 0;
    check('h24, 9);
    check('h28, 9);
    send(0, 1);
    send(0, 2);
    flush_i = 1;
    tick();
    flush_i = 0;
    check('h34, 2);
    force dut.written = 64'h00000000ffffffff;
    #1;
    release dut.written;
    written_i[0] = 1;
    tick();
    written_i = 0;
    check('h2c, 0);
    rst_ni = 0;
    tick();
    rst_ni = 1;
    check('h24, 0);
    check('h28, 0);
    check('h2c, 0);
    check('h64, 0);
    check('h70, 0);
    check('h74, 0);
    check('h7c, 0);
    $display(
        "QUANT SYNC PASS checks=%0d elastic-II1/owners/stalls/parameter-sampling/ACK-counts/flush/cancel/wrap/reset",
        checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "quant sync timeout");
  end
endmodule
