`timescale 1ns / 1ps
module tb_irq_control;
  logic clk = 0, rst = 0, req = 0, we = 0;
  always #10 clk = ~clk;
  logic [11:0] addr = 0;
  logic [31:0] data = 0;
  wire [31:0] rd;
  wire err;
  logic [1:0] busy = 0, done = 0, fault = 0;
  wire [1:0] irq;
  npu_mmio mmio (
    .mat_observe_i (32'b0),
    .vec_observe_i (32'b0),
    .clk_i         (clk),
    .rst_ni        (rst),
    .req_i         (req),
    .we_i          (we),
    .addr_i        (addr),
    .wdata_i       (data),
    .rdata_o       (rd),
    .error_o       (err),
    .cache_hits_i  (64'b0),
    .cache_misses_i(64'b0),
    .bank_accepts_i(64'b0),
    .mat_busy_i    (busy[0]),
    .mat_done_i    (done[0]),
    .mat_fault_i   (fault[0]),
    .mat_blocked_i (1'b0),
    .vec_busy_i    (busy[1]),
    .vec_done_i    (done[1]),
    .vec_fault_i   (fault[1]),
    .irq_o         (irq)
  );
  logic creq = 0, cwe = 0;
  logic [7:0] ca = 0;
  logic [31:0] cd = 0;
  wire [31:0] cr;
  wire ce, ci;
  npu_stream_pkg::stream_events_t events = '0;
  npu_stream_control #(
    .QUEUE_DEPTH(8)
  ) cnn (
    .observe_i   (32'b0),
    .clk_i       (clk),
    .rst_ni      (rst),
    .quant_pack_i(1'b0),
    .csr_req_i   (creq),
    .csr_we_i    (cwe),
    .blocked_i   (1'b0),
    .csr_addr_i  (ca),
    .csr_wdata_i (cd),
    .events_i    (events),
    .csr_rdata_o (cr),
    .csr_error_o (ce),
    .irq_o       (ci)
  );
  int checks = 0;
  task automatic command(input int a, d, input logic [1:0] dm = 0, fm = 0);
    @(negedge clk);
    addr = 12'(a);
    data = 32'(d);
    req = 1;
    we = 1;
    done = dm;
    fault = fm;
    #1;
    if (err) $fatal(1, "unexpected CSR error %h", a);
    @(negedge clk);
    req = 0;
    we = 0;
    done = 0;
    fault = 0;
  endtask
  task automatic check(input int a, value, input logic [1:0] levels);
    addr = 12'(a);
    #1;
    if (rd !== 32'(value) || irq !== levels)
      $fatal(1, "control a=%h rd=%h expected=%h irq=%b/%b", a, rd, value, irq, levels);
    checks++;
  endtask
  task automatic ccommand(input int value, input bit event_done = 0, event_fault = 0);
    @(negedge clk);
    creq = 1;
    cwe = 1;
    ca = 0;
    cd = 32'(value);
    events.done = event_done;
    events.fault = event_fault;
    #1;
    if (ce) $fatal(1, "CNN CSR error");
    @(negedge clk);
    creq = 0;
    cwe = 0;
    events.done = 0;
    events.fault = 0;
  endtask
  task automatic ccheck(input int a, value, input bit level);
    ca = 8'(a);
    #1;
    if (cr !== 32'(value) || ci !== level)
      $fatal(1, "CNN a=%h rd=%h expected=%h irq=%b/%b", a, cr, value, ci, level);
    checks++;
  endtask
  initial begin
    repeat (4) @(negedge clk);
    rst = 1;
    check('h070, 'h70000, 0);
    check('h080, 'hf, 0);
    check('h040, 'h00020002, 0);
    check('h074, 'h01001010, 0);
    check('h078, 4096, 0);
    check('h07c, 256, 0);
    for (int u = 0; u < 2; u++) begin
      int base;
      base = u == 0 ? 'h100 : 'h200;
      command(base, 8, 2'(1 << u));
      check(base + 4, 2, 2'(1 << u));
      check(base + 'h28, 1, 2'(1 << u));
      busy[u] = 1;
      command(base, 8);
      check(base + 4, 1, 0);
      check(base + 'h28, 1, 0);
      // New completion wins simultaneous W1C while another task is active.
      command(base, 8, 2'(1 << u));
      check(base + 4, 3, 2'(1 << u));
      check(base + 'h28, 2, 2'(1 << u));
      // An error wakes even without done; done acknowledgement never hides it.
      command(base, 8, 0, 2'(1 << u));
      check(base + 4, 5, 2'(1 << u));
      check(base + 'h28, 2, 2'(1 << u));
      busy[u] = 0;
      command(base, 2, 0, 2'(1 << u));
      check(base + 4, 4, 2'(1 << u));
      command(base, 8);
      check(base + 4, 4, 2'(1 << u));
      command(base, 2);
      check(base + 4, 0, 0);
      check(u == 0 ? 'h14c : 'h280, 2, 0);
    end
    command('h100, 0, 3);
    check('h104, 2, 3);
    check('h204, 2, 3);
    command('h100, 8);
    check('h104, 0, 2);
    check('h204, 2, 2);
    command('h200, 8);
    check('h204, 0, 0);
    ccommand(8, 1);
    ccheck(4, 2, 1);
    ccheck('h5c, 1, 1);
    events.busy = 1;
    ccommand(8);
    ccheck(4, 1, 0);
    ccheck('h5c, 1, 0);
    ccommand(2, 0, 1);
    ccheck(4, 5, 1);
    ccommand(8);
    ccheck(4, 5, 1);
    events.busy = 0;
    ccommand(2);
    ccheck(4, 0, 0);
    // Fault dominates simultaneous successful completion and acknowledgement.
    events.busy = 1;
    ccommand(2, 1, 1);
    events.busy = 0;
    ccheck(4, 4, 1);
    ccheck('h5c, 1, 1);
    ccheck('h3c, 2, 1);
    ccommand(2);
    ccheck(4, 0, 0);
    $display(
        "IRQ CONTROL PASS checks=%0d active-W1C/set-dominant/fault-wakeup/independent-levels/tickets",
        checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "IRQ control timeout");
  end
endmodule
