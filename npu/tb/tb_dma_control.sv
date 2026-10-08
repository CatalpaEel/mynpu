`timescale 1ns/1ps
// Exercise cancellation exactly when an accepted write returns its response.
module tb_dma_control;
  logic clk=0,rst_n=0,start=0,abort_req=0;
  always #10 clk=~clk;
  logic [1:0] mode=3;
  logic [31:0] timeout_limit=0;
  wire busy,done,fault;
  wire [3:0] fault_code;
  wire [31:0] bytes_done,cycles;
  logic gnt=0,rvalid=0,error=0;
  wire req,we,stream_abort;
  npu_dma_channel dut (
    .clk_i(clk),.rst_ni(rst_n),.start_i(start),.abort_i(abort_req),.mode_i(mode),
    .src_i(32'h80000000),.dst_i(32'h80000100),.row_bytes_i(32'd4),.rows_i(32'd1),
    .src_stride_i(32'd4),.dst_stride_i(32'd4),.fill_i(32'h12345678),.timeout_i(timeout_limit),
    .busy_o(busy),.done_o(done),.fault_o(fault),.fault_code_o(fault_code),
    .bytes_done_o(bytes_done),.cycles_o(cycles),
    .rx_valid_i(1'b0),.rx_ready_o(),.rx_data_i(32'b0),.rx_keep_i(4'b0),.rx_last_i(1'b0),
    .tx_valid_o(),.tx_ready_i(1'b0),.tx_data_o(),.tx_keep_o(),.tx_last_o(),.stream_abort_o(stream_abort),
    .req_o(req),.we_o(we),.be_o(),.addr_o(),.wdata_o(),
    .gnt_i(gnt),.rvalid_i(rvalid),.error_i(error),.rdata_i(32'b0)
  );
  task automatic launch(input int op,limit);
    @(negedge clk);mode=2'(op);timeout_limit=32'(limit);start=1;
    @(negedge clk);start=0;
  endtask
  initial begin
    repeat(5) @(negedge clk);rst_n=1;
    launch(3,0);gnt=1;
    @(posedge clk);if(!req || !we) $fatal(1,"No accepted fill write");
    @(negedge clk);gnt=0;rvalid=1;abort_req=1;
    @(negedge clk);rvalid=0;abort_req=0;
    if(busy || !fault || fault_code!=5 || bytes_done!=4 || done) $fatal(1,"Abort lost committed write accounting");
    launch(3,2);gnt=1;
    @(posedge clk);if(!req) $fatal(1,"No fill request");
    @(negedge clk);gnt=0;rvalid=1;
    @(negedge clk);rvalid=0;
    if(busy || !fault || fault_code!=6 || bytes_done!=4) $fatal(1,"Timeout lost committed write accounting");
    // Read bus error must not export a stale TX word.
    launch(1,0);gnt=1;
    @(posedge clk);
    @(negedge clk);gnt=0;rvalid=1;error=1;
    @(negedge clk);rvalid=0;error=0;
    if(busy || !fault || fault_code!=4 || bytes_done!=0 || !stream_abort) $fatal(1,"Read fault not propagated");
    // Abort before a stalled memory request is granted must suppress acceptance.
    launch(3,0);abort_req=1;
    #1;if(req) $fatal(1,"Canceled write still requesting SRAM");
    @(negedge clk);abort_req=0;
    if(busy || !fault || bytes_done!=0 || fault_code!=5) $fatal(1,"Cancel before grant failed");
    $display("PASS DMA control: abort/timeout preserve committed writes, cancel-before-grant and bus faults");
    $finish;
  end
endmodule
