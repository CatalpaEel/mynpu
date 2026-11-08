`timescale 1ns / 1ps
module tb_store_pack;
  logic clk_i = 0, rst_ni = 0, flush_i = 0, enable_i = 1, valid_i = 0, last_i = 0, gnt_i = 0;
  always #10 clk_i = ~clk_i;
  logic ready_o, busy_o, req_o;
  logic [31:0] addr_i = 0, addr_o, data_o;
  logic [7:0] data_i = 0;
  logic [3:0] be_o, cancelled_o;
  logic [2:0] count_o;
  int checks = 0;
  npu_store_pack dut (.*);
  task automatic tick;
    @(posedge clk_i);
    #1;
    @(negedge clk_i);
  endtask
  task automatic check(input bit ok, input string why);
    if (!ok) $fatal(1, "%s", why);
    checks++;
  endtask
  task automatic put(input int a, d, input bit last);
    addr_i = 32'(a);
    data_i = 8'(d);
    last_i = last;
    valid_i = 1;
    #1;
    check(ready_o, "unexpected input stall");
    tick();
    valid_i = 0;
  endtask
  initial begin
    repeat (3) tick();
    rst_ni = 1;
    put('h80001801, 'h11, 0);
    put('h80001802, 'h22, 0);
    put('h80001803, 'h33, 1);
    check(req_o && addr_o == 'h80001800 && be_o == 14 && count_o == 3 && data_o[31:8] == 'h332211,
          "tail merge");
    repeat (4) begin
      tick();
      check(req_o && be_o == 14 && count_o == 3, "stalled write changed");
    end
    gnt_i = 1;
    tick();
    gnt_i = 0;
    check(!busy_o, "write grant did not consume");
    for (int n = 0; n < 4; n++) put('h80001804 + n, n, 0);
    check(req_o && be_o == 15 && count_o == 4 && data_o == 'h03020100, "full word not sealed");
    gnt_i = 1;
    tick();
    gnt_i = 0;
    put('h80001808, 9, 0);
    addr_i = 'h80001810;
    data_i = 10;
    valid_i = 1;
    #1;
    check(req_o && !ready_o && addr_o == 'h80001808, "noncontiguous address did not drain");
    gnt_i = 1;
    tick();
    gnt_i = 0;
    check(ready_o, "new word not accepted after drain");
    tick();
    valid_i = 0;
    enable_i = 0;
    #1;
    check(req_o && addr_o == 'h80001810 && be_o == 1, "configuration switch did not drain");
    gnt_i = 1;
    tick();
    gnt_i = 0;
    enable_i = 1;
    put('h80001820, 1, 0);
    put('h80001821, 2, 0);
    flush_i = 1;
    #1;
    check(cancelled_o == 2 && !req_o && !ready_o, "flush accounting");
    tick();
    flush_i = 0;
    check(!busy_o && cancelled_o == 0, "flush did not empty");
    put('h80001820, 3, 0);
    addr_i = 'h80001820;
    valid_i = 1;
    #1;
    check(req_o && !ready_o, "repeated byte incorrectly merged");
    valid_i = 0;
    rst_ni = 0;
    tick();
    rst_ni = 1;
    check(!busy_o && !req_o, "reset retained a write");
    $display(
        "STORE PACK PASS checks=%0d merge/tails/full-word/backpressure/address-change/config-change/flush/repeated-byte/reset",
        checks);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "store pack timeout");
  end
endmodule
