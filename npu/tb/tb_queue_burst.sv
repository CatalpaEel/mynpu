`timescale 1ns / 1ps
module tb_queue_burst;
  logic clk = 0;
  always #10 clk = ~clk;
  logic rst_n = 0, cpu_run = 1;
  logic hreq = 0, hwe = 0;
  logic [3:0] hbe = 4'hf;
  logic [31:0] haddr = 0, hwdata = 0;
  wire hgnt, hrvalid, herror;
  wire [31:0] hrdata;
  wire [4:0] irq;
  logic rx_valid = 0, rx_last = 0, tx_ready = 0;
  logic [31:0] rx_data = 0;
  logic [3:0] rx_keep = 4'hf;
  wire rx_ready, rx_abort, tx_valid, tx_last, tx_abort;
  wire [31:0] tx_data;
  wire [3:0] tx_keep;
  logic [31:0] boot_image[0:511];
  wire cpu_done, cpu_pass;
  localparam logic [31:0] SRAM = 32'h80000000, MMIO = 32'h40000000;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (cpu_run),
    .tck_i             (1'b0),
    .tms_i             (1'b1),
    .td_i              (1'b0),
    .td_o              (),
    .cpu_debug_halted_o(),
    .host_req_i        (hreq),
    .host_we_i         (hwe),
    .host_be_i         (hbe),
    .host_addr_i       (haddr),
    .host_wdata_i      (hwdata),
    .host_gnt_o        (hgnt),












    .host_rvalid_o  (hrvalid),
    .host_error_o   (herror),
    .host_rdata_o   (hrdata),
    .irq_o          (irq),
    .cpu_test_done_o(cpu_done),
    .cpu_test_pass_o(cpu_pass)
  );
  int checks = 0, transactions = 0, mat_jobs = 0;
  int max_host_wait = 0;
  int rx_aborts = 0, tx_aborts = 0;
  always @(posedge clk) begin
    if (rx_abort) rx_aborts++;
    if (tx_abort) tx_aborts++;
  end
  task automatic transfer(input bit wr, input logic [31:0] a, d, input logic [3:0] mask,
                          input bit expected_error, output logic [31:0] result);
    int waited;
    @(negedge clk);
    hreq = 1;
    hwe = wr;
    haddr = a;
    hwdata = d;
    hbe = mask;
    waited = 0;
    do begin
      @(posedge clk);
      waited++;
      if (waited > 8) $fatal(1, "Host starved, addr=%h", a);
    end while (!hgnt);
    if (waited > max_host_wait) max_host_wait = waited;
    @(negedge clk);
    hreq = 0;
    if (!hrvalid) @(negedge clk);  // Registered MMIO responds one cycle after SRAM.
    if (!hrvalid) $fatal(1, "Missing response addr=%h", a);
    if (herror !== expected_error)
      $fatal(1, "Bus error addr=%h got=%b expected=%b", a, herror, expected_error);
    result = hrdata;
    transactions++;
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    transfer(1, a, d, 4'hf, 0, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    transfer(0, a, 0, 4'hf, 0, d);
  endtask
  task automatic expect_word(input logic [31:0] a, d);
    logic [31:0] got;
    rd(a, got);
    if (got !== d) $fatal(1, "Mismatch addr=%h got=%h expected=%h", a, got, d);
    checks++;
  endtask
  task automatic wait_unit(input logic [31:0] status_addr, input bit allow_error = 0);
    logic [31:0] s;
    bit finished;
    finished = 0;
    for (int t = 0; t < 40000 && !finished; t++) begin
      rd(status_addr, s);
      if (s[2] && !allow_error) $fatal(1, "Unexpected command error status=%h", s);
      finished = s[1] && !s[0];
    end
    if (!finished) $fatal(1, "Unit timeout %h", status_addr);
    checks++;
  endtask
  longint ticks = 0, begin_tick, submit_tick, end_tick;
  int peak_mat = 0, peak_vec = 0, mat_depth, vec_depth;
  always @(posedge clk) begin
    ticks++;
`ifndef NPU_GATE_SIM
    if (int'(dut.i_core.i_mmio.mc) > peak_mat) peak_mat = int'(dut.i_core.i_mmio.mc);
    if (int'(dut.i_core.i_mmio.vc) > peak_vec) peak_vec = int'(dut.i_core.i_mmio.vc);
`endif
  end
  task automatic space(input int q, status);
    logic [31:0] v, s;
    for (int t = 0; t < 100000; t++) begin
      rd(MMIO + 32'(q), v);
      if ((v & 65535) < (v >> 16)) return;
      rd(MMIO + 32'(status), s);
      if (s[2]) $fatal(1, "Queue error");
    end
    $fatal(1, "Queue wait timeout");
  endtask
  initial begin
    logic [31:0] v;
    repeat (5) @(negedge clk);
    rst_n = 1;
    rd(MMIO + 'h124, v);
    mat_depth = int'(v >> 16);
    rd(MMIO + 'h224, v);
    vec_depth = int'(v >> 16);
    for (int j = 0; j < 16; j++) begin
      wr(SRAM + 'h100 + 32'(j * 4), 32'h01010101);
      wr(SRAM + 'h2000 + 32'(j * 4), 32'h02020202);
    end
    for (int j = 0; j < 256; j++) wr(SRAM + 'h2400 + 32'(j * 4), 32'(j - 128));
    wr(MMIO + 'h108, SRAM + 'h100);
    wr(MMIO + 'h10c, SRAM + 'h2000);
    wr(MMIO + 'h114, 4);
    wr(MMIO + 'h118, 4);
    wr(MMIO + 'h11c, 16);
    wr(MMIO + 'h130, 8);
    wr(MMIO + 'h208, SRAM + 'h2400);
    wr(MMIO + 'h20c, SRAM + 'h2400);
    wr(MMIO + 'h210, 256);
    wr(MMIO + 'h214, 129);
    begin_tick = ticks;
    // One MMIO producer submits an interleaved batch, then is free for other work.
    for (int j = 0; j < 16; j++) begin
      space('h124, 'h104);
      wr(MMIO + 'h110, SRAM + 'h400 + 32'(j * 64));
      wr(MMIO + 'h100, 1);
      space('h224, 'h204);
      wr(MMIO + 'h230, 32'(j + 1));
      wr(MMIO + 'h200, 1);
    end
    submit_tick = ticks;
    wait_unit(MMIO + 'h104);
    wait_unit(MMIO + 'h204);
    end_tick = ticks;
    expect_word(MMIO + 'h128, 16);
    expect_word(MMIO + 'h228, 16);
    for (int j = 0; j < 256; j++) begin
      expect_word(SRAM + 'h400 + 32'(j * 4), 32);
      expect_word(SRAM + 'h2400 + 32'(j * 4), 32'(j - 128 + 136));
    end
`ifndef NPU_GATE_SIM
    $display(
        "BURST PASS matrix_depth=%0d vector_depth=%0d matrix_jobs=16 vector_jobs=16 submit_cycles=%0d total_cycles=%0d matrix_pending_peak=%0d vector_pending_peak=%0d checks=%0d",
        mat_depth, vec_depth, submit_tick - begin_tick, end_tick - begin_tick, peak_mat, peak_vec,
        checks);
`else
    $display(
        "BURST PASS matrix_depth=%0d vector_depth=%0d matrix_jobs=16 vector_jobs=16 submit_cycles=%0d total_cycles=%0d checks=%0d",
        mat_depth, vec_depth, submit_tick - begin_tick, end_tick - begin_tick, checks);
`endif
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "Burst timeout");
  end
endmodule
