`timescale 1ns / 1ps
// Compact stream tasks retain immutable shared configuration and backpressure.
module tb_cnn_queue;
  import npu_stream_pkg::*;
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0, csr_req_i = 0, csr_we_i = 0, blocked_i = 0, pending_i = 0;
  always #10 clk_i = ~clk_i;
  logic [7:0] csr_addr_i = 0;
  logic [31:0] csr_wdata_i = 0, csr_rdata_o;
  logic csr_error_o, busy_o, done_o, irq_o, req_o, we_o;
  logic [3:0] be_o;
  logic [31:0] addr_o, wdata_o;
  logic gnt_i, rvalid_i = 0, error_i = 0;
  logic [31:0] rdata_i = 0;
  logic result_valid_o, result_ready_i = 0;
  logic [31:0] result_data_o;
  logic [2:0] gather_req_o, gather_gnt_i = 0, gather_valid_i = 0, gather_error_i = 0;
  logic [2:0][31:0] gather_addr_o, gather_data_i = 0;
  logic
      mac_valid_o,
      mac_flush_o,
      mac_clear_o,
      mac_load_o,
      mac_emit_o,
      mac_ready_i,
      mac_result_valid_i,
      mac_result_ready_o;
  logic signed [8:0] mac_a_o[9], mac_offset_o;
  logic signed [7:0] mac_w_o[9];
  logic [8:0] mac_mask_o;
  logic [31:0] mac_seed_o, mac_result_data_i;
  logic allow_bus = 0;
  logic [7:0] mem[16384];
  assign gnt_i = allow_bus && req_o;
  npu_stream dut (
    .rf_sink_be_o    (),
    .quant_pack_i    (1'b0),
    .quant_enable_i  (1'b0),
    .quant_dst_i     (32'b0),
    .quant_final_o   (),
    .result_pending_i(1'b0),
    .rf_sink_req_o   (),
    .rf_sink_addr_o  (),
    .rf_sink_wdata_o (),
    .rf_sink_gnt_i   (1'b0),
    .rf_sink_rvalid_i(1'b0),
    .rf_sink_error_i (1'b0),
    .*
  );
  npu_cnn arithmetic (
    .clk_i,
    .rst_ni,
    .flush_i (mac_flush_o),
    .valid_i (mac_valid_o),
    .ready_o (mac_ready_i),
    .a_i     (mac_a_o),
    .offset_i(mac_offset_o),
    .w_i     (mac_w_o),
    .mask_i  (mac_mask_o),
    .clear_i (mac_clear_o),
    .load_i  (mac_load_o),
    .emit_i  (mac_emit_o),
    .seed_i  (mac_seed_o),
    .valid_o (mac_result_valid_i),
    .ready_i (mac_result_ready_o),
    .data_o  (mac_result_data_i)
  );
  int checks = 0, depth;
  always @(posedge clk_i) begin
    rvalid_i <= gnt_i;
    if (gnt_i)
      for (int b = 0; b < 4; b++) begin
        rdata_i[b*8+:8] <= mem[{addr_o[13:2], 2'b0}+b];
        if (we_o && be_o[b]) mem[{addr_o[13:2], 2'b0}+b] <= wdata_o[b*8+:8];
      end
  end
  task automatic wr(input int a, input logic [31:0] d, input bit err = 0);
    @(negedge clk_i);
    csr_req_i = 1;
    csr_we_i = 1;
    csr_addr_i = 8'(a);
    csr_wdata_i = d;
    #1;
    if (csr_error_o !== err) $fatal(1, "CSR a=%h expected error=%b got=%b", a, err, csr_error_o);
    checks++;
    @(negedge clk_i);
    csr_req_i = 0;
    csr_we_i = 0;
  endtask
  task automatic expect_csr(input int a, input logic [31:0] d);
    @(negedge clk_i);
    csr_addr_i = 8'(a);
    #1;
    if (csr_rdata_o !== d) $fatal(1, "CSR %h got=%h expected=%h", a, csr_rdata_o, d);
    checks++;
  endtask
  task automatic configure;
    wr('h08, 32'h80001400);
    wr('h0c, 32'h800020a2);
    wr('h10, 32'h80001800);
    wr('h14, 1);
    wr('h18, RF_BASE + RF_BYTES - 64);
    wr('h1c, 1);
    wr('h20, 1);
    wr('h24, 2);
    wr('h2c, 0);
    wr('h30, 2, 1);  // removed direct-result mode must be rejected
    wr('h30, 0);
  endtask
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 'ha5;
    mem['h1400] = 2;
    mem['h1401] = 3;
    for (int c = 0; c < 32; c++) begin
      for (int t = 0; t < 9; t++) mem['h2000+c*9+t] = 0;
      mem['h2000+c*9+4] = 8'(c + 1);
    end
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    csr_addr_i = 'h58;
    #1;
    depth = int'(csr_rdata_o >> 16);
    configure();
    expect_csr('h54, 32'h53443935);
    expect_csr('h70, 32'h00100020);
    wr('h0c, 32'h80003ffc);
    for (int n = 1; n <= 16; n += 15) begin
      wr('h28, encode_task(0, 0, n, 2, 1, 1, 0));
      wr(0, 1);
      expect_csr(4, 4);
      expect_csr('h60, 0);
      wr(0, 2);
    end
    wr('h0c, 32'h800020a2);
    for (int i = 0; i <= depth; i++) begin
      wr('h28, encode_task(i / 16, 0, 1, 2, 1, 1, i));
      wr(0, 1);
    end
    expect_csr('h58, 32'(depth << 16 | depth));
    expect_csr('h60, 32'(depth + 1));
    wr(0, 1, 1);  // overflow cannot replace a queued task
    wr('h14, 2, 1);
    expect_csr('h14, 1);  // immutable live configuration
    wr('h28, 0);  // shadows cannot change any task already in the FIFO
    wr('h0c, 32'h80002004, 1);
    expect_csr('h0c, 32'h800020a2);
    pending_i = 1;
    allow_bus = 1;
    for (int t = 0; t < 20000 && busy_o; t++) @(negedge clk_i);
    if (busy_o) $fatal(1, "Stream queue failed to drain");
    expect_csr('h5c, 32'(depth + 1));
    expect_csr(4, 2);
    for (int i = 0; i <= depth; i++) begin
      logic [31:0] got;
      for (int b = 0; b < 4; b++) got[b*8+:8] = mem['h1800+i*4+b];
      if (got !== 32'((i / 16 + 2) * 19))
        $fatal(1, "Task snapshot/order failure i=%0d got=%0d", i, got);
      checks++;
    end
    if (mem['h17ff] !== 8'ha5 || mem['h1800+(depth+1)*4] !== 8'ha5) $fatal(1, "Output bounds");
    pending_i = 0;
    allow_bus = 0;
    wr('h28, encode_task(0, 0, 1, 2, 1, 1, 0));
    wr(0, 1);
    wr(0, 1);
    @(negedge clk_i);
    rst_ni = 0;
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    expect_csr('h60, 0);
    expect_csr('h5c, 0);
    expect_csr(4, 0);
    blocked_i = 1;
    wr(0, 1, 1);
    blocked_i = 0;
    pending_i = 1;
    wr(0, 1, 1);
    pending_i = 0;
    configure();
    wr('h28, encode_task(0, 0, 1, 2, 1, 1, 0));
    wr(0, 1);
    wr(0, 1);
    error_i = 1;
    allow_bus = 1;
    repeat (12) @(negedge clk_i);
    expect_csr(4, 4);
    expect_csr('h58, 32'(depth << 16));
    wr(0, 8);
    expect_csr(4, 4);
    wr(0, 1, 1);
    expect_csr('h60, 2);
    error_i = 0;
    wr(0, 2);
    wr('h0c, 32'h12340000, 1);
    wr('h0c, 32'h80003ffc);  // base valid, but complete nine-byte kernel crosses SRAM
    wr(0, 1);
    expect_csr(4, 4);
    expect_csr('h60, 2);
    wr(0, 2);
    wr('h0c, 32'h800020a2);
    // Check actual task span at START: a 32B workspace cannot hold 16 partials.
    wr('h18, RF_BASE + RF_BYTES - 32);
    expect_csr('h18, RF_BASE + RF_BYTES - 32);
    wr('h28, encode_task(0, 0, 16, 2, 1, 1, 0));
    wr(0, 1);
    expect_csr(4, 4);
    expect_csr('h60, 2);
    wr('h18, RF_BASE + RF_BYTES, 1);
    wr(0, 2);
    wr('h28, encode_task(0, 0, 8, 2, 1, 1, 0));
    wr(0, 1);  // The same last-32B workspace is valid for a shorter task.
    for (int t = 0; t < 20000 && busy_o; t++) @(negedge clk_i);
    if (busy_o) $fatal(1, "short workspace task failed to drain");
    expect_csr('h60, 3);
    expect_csr('h5c, 1);
    expect_csr(4, 2);
    if ($bits(dut.command) != 32) $fatal(1, "Task FIFO is not 32 bits");
    $display(
        "CNN QUEUE PASS depth=%0d descriptor_bits=%0d checks=%0d shared immutable kernel, compact window tasks, order, overflow, reset, faults",
        depth, $bits(dut.command), checks);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1, "Stream queue timeout");
  end
endmodule
