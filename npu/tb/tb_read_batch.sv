`timescale 1ns / 1ps
module tb_read_batch;
  logic clk_i = 0, rst_ni = 0, valid_i = 0, ready_i = 0;
  always #10 clk_i = ~clk_i;
  logic ready_o, valid_o;
  logic [2:0]
      mask_i = 0, error_o, gather_req_o, gather_gnt_i = 0, gather_valid_i = 0, gather_error_i = 0;
  logic [2:0][31:0] addr_i = 0, data_o, gather_addr_o, gather_data_i = 0;
  logic req_o, gnt_i = 0, rvalid_i = 0, error_i = 0;
  logic [31:0] addr_o, rdata_i = 0;
  int checks = 0;
  npu_multi_read dut (.*);
  task automatic tick;
    @(posedge clk_i);
    #1;
    @(negedge clk_i);
  endtask
  task automatic check(input bit ok, input string msg);
    if (!ok) $fatal(1, "%s", msg);
    checks++;
  endtask
  task automatic launch;
    check(ready_o, "adapter unavailable");
    valid_i = 1;
    tick();
    valid_i = 0;
  endtask
  initial begin
    tick();
    rst_ni = 1;
    tick();
    // Three independent reads; stagger grants and replies, then hold output.
    mask_i = 7;
    addr_i = {32'h80000000, 32'h80004004, 32'h80004000};
    launch();
    check(gather_req_o == 3 && req_o, "mixed batch routing");
    gather_gnt_i = 1;
    tick();
    gather_gnt_i = 0;
    check(gather_req_o == 2, "granted RF lane reissued");
    gather_valid_i = 1;
    gather_data_i[0] = 11;
    gather_gnt_i = 2;
    gnt_i = 1;
    tick();
    gather_valid_i = 0;
    gather_gnt_i = 0;
    gnt_i = 0;
    check(!req_o && gather_req_o == 0 && !valid_o, "pending ownership");
    rvalid_i = 1;
    rdata_i = 33;
    tick();
    rvalid_i = 0;
    check(!valid_o, "incomplete response exposed");
    gather_valid_i = 2;
    gather_data_i[1] = 22;
    tick();
    gather_valid_i = 0;
    for (int k = 0; k < 5; k++) begin
      check(valid_o && error_o == 0 && data_o == {32'd33, 32'd22, 32'd11},
            "response changed under backpressure");
      check(!req_o && gather_req_o == 0, "completed batch reissued");
      tick();
    end
    ready_i = 1;
    tick();
    ready_i = 0;
    check(ready_o, "consume did not release");
    // A failing RF lane must drain the other granted RF/SRAM requests.
    launch();
    gather_gnt_i = 3;
    gnt_i = 1;
    tick();
    gather_gnt_i = 0;
    gnt_i = 0;
    gather_valid_i = 1;
    gather_error_i = 1;
    tick();
    gather_valid_i = 0;
    gather_error_i = 0;
    check(!valid_o, "fault discarded pending responses");
    rvalid_i = 1;
    rdata_i = 55;
    tick();
    rvalid_i = 0;
    check(!valid_o, "fault discarded pending RF response");
    gather_valid_i = 2;
    gather_data_i[1] = 44;
    tick();
    gather_valid_i = 0;
    check(valid_o && error_o == 1 && data_o[1] == 44 && data_o[2] == 55, "fault drain result");
    ready_i = 1;
    tick();
    ready_i = 0;
    // Fault before the ordinary request is granted cancels that request.
    launch();
    gather_gnt_i = 3;
    tick();
    gather_gnt_i = 0;
    gather_valid_i = 3;
    gather_error_i = 2;
    tick();
    gather_valid_i = 0;
    gather_error_i = 0;
    check(valid_o && error_o == 2 && !req_o, "ungranted lane not cancelled");
    ready_i = 1;
    tick();
    ready_i = 0;
    mask_i = 0;
    launch();
    check(valid_o && error_o == 0, "empty batch");
    ready_i = 1;
    tick();
    ready_i = 0;
    mask_i = 7;
    launch();
    gather_gnt_i = 3;
    gnt_i = 1;
    tick();
    gather_gnt_i = 0;
    gnt_i = 0;
    rst_ni = 0;
    tick();
    check(!valid_o && !req_o && gather_req_o == 0, "reset retained request");
    rst_ni = 1;
    tick();
    check(ready_o, "reset recovery");
    $display("READ BATCH PASS checks=%0d delayed/partial grants, faults/drain, backpressure, reset",
             checks);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
