`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_layout_events;
  logic clk = 0, rst_n = 0, hreq = 0, hwe = 0;
  always #10 clk = ~clk;
  logic [31:0] ha = 0, hd = 0;
  wire hg, hv, he;
  wire [31:0] hr;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b0),
    .tck_i             (1'b0),
    .tms_i             (1'b1),
    .td_i              (1'b0),
    .td_o              (),
    .cpu_debug_halted_o(),
    .host_req_i        (hreq),
    .host_we_i         (hwe),
    .host_be_i         (4'hf),
    .host_addr_i       (ha),
    .host_wdata_i      (hd),
    .host_gnt_o        (hg),
    .host_rvalid_o     (hv),
    .host_error_o      (he),
    .host_rdata_o      (hr),
    .irq_o             (),
    .cpu_test_done_o   (),
    .cpu_test_pass_o   ()
  );
  int checks = 0;
  localparam logic [31:0] INPUT_A=32'h80001400, OUTPUT_D=32'h80001700,
    WEIGHTS=32'h80002000, MATRIX_B=32'h80002020, CHANNEL=32'h80006000;
  task automatic bus(input bit we, input logic [31:0] a, d, output logic [31:0] result);
    int cycles;
    @(negedge clk);
    hreq = 1;
    hwe = we;
    ha = a;
    hd = d;
    cycles = 0;
    do begin
      @(posedge clk);
      cycles++;
      if (cycles > 100) $fatal(1, "host grant timeout %h", a);
    end while (!hg);
    @(negedge clk);
    hreq = 0;
    if (!hv) @(negedge clk);
    if (!hv || he) $fatal(1, "host response/error %h", a);
    result = hr;
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    bus(1, a, d, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    bus(0, a, 0, d);
  endtask
  localparam logic [31:0] M=32'h40000000,A=32'h80001000,B=32'h80002000,
      D=32'h80003000,E=32'h80003200;
  int controls[3] = '{'h100, 'h200, 'h600};
  task automatic expect_word(input logic [31:0] address, value);
    logic [31:0] got;
    rd(address, got);
    if (got !== value)
      $fatal(1, "layout/event mismatch address=%h got=%h expected=%h", address, got, value);
    checks++;
  endtask
  task automatic restart;
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);
  endtask
  task automatic wait_done(input int unit_id);
    logic [31:0] value;
    for (int t = 0; t < 10000; t++) begin
      rd(M + controls[unit_id] + 4, value);
      if (value[2]) $fatal(1, "unexpected engine fault unit=%0d", unit_id);
      if (value[1] && !value[0]) return;
    end
    $fatal(1, "layout/event timeout unit=%0d", unit_id);
  endtask
  task automatic vector(input logic [31:0] a, b, d, input int count, op, astep, bstep, dstep,
                        layout, events, scalar = 0);
    wr(M + 'h208, a);
    wr(M + 'h218, b);
    wr(M + 'h20c, d);
    wr(M + 'h210, count);
    wr(M + 'h214, op);
    wr(M + 'h230, scalar);
    wr(M + 'h28c, astep);
    wr(M + 'h290, bstep);
    wr(M + 'h294, dstep);
    wr(M + 'h298, layout);
    wr(M + 'h29c, events);
    wr(M + 'h200, 1);
  endtask
  initial begin
    logic [31:0] status;
    restart();
    expect_word(M + 'h088, 32'h45563031);
    expect_word(M + 'h094, 32'h4c593031);
    expect_word(M + 'h28c, 4);
    expect_word(M + 'h294, 4);
    for (int i = 0; i < 8; i++) begin
      wr(A + i * 4, 10 + i);
      wr(B + i * 4, 32'(i * 3 - 1));
    end
    // Two queued jobs capture different layouts, masks and destinations while
    // the head waits. Editing every CSR afterward must not change either job.
    vector(A, B, D, 4, 1, 0, 4, 4, 4, 'h0201);
    vector(D + 12, B + 8, E + 12, 4, 1, -4, 0, -4, 4, 'h0402);
    wr(M + 'h28c, 2048);
    wr(M + 'h290, -2048);
    wr(M + 'h294, 0);
    wr(M + 'h298, 7);
    wr(M + 'h29c, 'hffff);
    rd(M + 'h288, status);
    if (!status[5]) $fatal(1, "vector missing event blocked flag");
    checks++;
    expect_word(M + 'h238, 0);
    wr(M + 'h08c, 1);
    wait_done(1);
    for (int i = 0; i < 4; i++) begin
      expect_word(D + i * 4, 32'(9 + 3 * i));
      expect_word(E + i * 4, 32'(14 + 3 * i));  // reverse read and reverse write; B[2]=5
    end
    expect_word(M + 'h08c, 7);
    // Explicit zero output stride is legal: repeated writes, last result wins.
    wr(D + 4, 32'hdeadbeef);
    vector(A, 0, D, 5, 2, 4, 0, 0, 4, 0);
    wait_done(1);
    expect_word(D, 14);
    expect_word(D + 4, 32'hdeadbeef);
    // SIMD stepping is per word; the final group preserves untouched bytes.
    wr(A, 32'h04030201);
    wr(A + 8, 32'h08070605);
    wr(D, 0);
    wr(D + 8, 32'hcccccccc);
    vector(A, 0, D, 6, 'hc1, 8, 0, 8, 4, 0, 1);
    wait_done(1);
    expect_word(D, 32'h05040302);
    expect_word(D + 8, 32'hcccc0706);
    // Only the last program result is stored. KEEP_R2 crosses task boundaries
    // without resetting the accumulator, using a loop-only two-op program.
    for (int i = 0; i < 5; i++) wr(A + i * 4, i + 1);
    wr(M + 'h240, 32'h0000009d);  // scalar -> r2
    wr(M + 'h244, 32'h00000281);  // add r2,r2,r0
    wr(M + 'h248, 32'h00000202);  // copy r0,r2
    wr(M + 'h234, 'h103);
    wr(D + 4, 32'hcafebabe);
    vector(A, A, D, 3, 'h20, 4, 4, 4, 1, 0, 0);
    wait_done(1);
    expect_word(D, 6);
    expect_word(D + 4, 32'hcafebabe);
    wr(M + 'h240, 32'h00000281);
    wr(M + 'h244, 32'h00000202);
    wr(M + 'h234, 2);
    vector(A + 12, A, E, 2, 'h20, 4, 4, 4, 3, 0, 0);
    wait_done(1);
    expect_word(E, 15);
    // Packed program byte stores support sparse, negative and zero D strides.
    wr(M + 'h240, 2);
    wr(M + 'h234, 1);
    for (int i = 0; i < 3; i++) wr(A + i * 4, 10 + i);
    wr(D, 32'hcccccccc);
    wr(D + 4, 32'hcccccccc);
    wr(D + 8, 32'hcccccccc);
    vector(A, A, D + 9, 3, 'h120, 4, 4, -4, 4, 0);
    wait_done(1);
    expect_word(D, 32'hcccc0ccc);
    expect_word(D + 4, 32'hcccc0bcc);
    expect_word(D + 8, 32'hcccc0acc);
    vector(A, A, D + 2, 3, 'h120, 4, 4, 0, 4, 0);
    wait_done(1);
    expect_word(D, 32'hcc0c0ccc);
    // Consumer enters Matrix before its Vector producer. No CPU completion
    // fence: the hardware event unblocks Matrix after the RF/SRAM store ACK.
    wr(M + 'h090, 255);
    wr(A, 5);
    wr(A + 4, 7);
    wr(B, -2);
    wr(B + 4, 3);
    wr(M + 'h108, E);
    wr(M + 'h10c, B);
    wr(M + 'h110, D);
    wr(M + 'h114, 1);
    wr(M + 'h118, 1);
    wr(M + 'h11c, 2);
    wr(M + 'h130, 0);
    wr(M + 'h134, 0);
    wr(M + 'h138, 0);
    wr(M + 'h13c, 0);
    wr(M + 'h140, 4);
    wr(M + 'h158, 0);
    wr(M + 'h15c, 'h1008);
    wr(M + 'h100, 1);
    rd(M + 'h154, status);
    if (!status[5]) $fatal(1, "matrix not event-blocked");
    checks++;
    vector(A, 0, E, 2, 2, 4, 4, 4, 0, 'h0800);
    wait_done(0);
    expect_word(D, 11);
    expect_word(M + 'h08c, 24);
    // CNN is the third independent event participant.
    wr(A, 3);
    wr(B, 0);
    wr(B + 4, 1);
    wr(B + 8, 0);
    wr(M + 'h608, A);
    wr(M + 'h60c, B);
    wr(M + 'h610, D);
    wr(M + 'h614, 1);
    wr(M + 'h618, 32'h800040c0);
    wr(M + 'h61c, 1);
    wr(M + 'h620, 1);
    wr(M + 'h624, 1);
    wr(M + 'h62c, 0);
    wr(M + 'h630, 0);
    wr(M + 'h628, 'h1a0);
    wr(M + 'h674, 'h4020);
    wr(M + 'h600, 1);
    rd(M + 'h650, status);
    if (!status[5]) $fatal(1, "CNN not event-blocked");
    checks++;
    wr(M + 'h08c, 32);
    wait_done(2);
    expect_word(D, 3);
    expect_word(M + 'h08c, 120);
    // Runtime bus error must not signal task success. Program creates an
    // invalid address in r1 via scalar, then LD32; its descriptor is accepted.
    wr(M + 'h240, 'h5d);
    wr(M + 'h244, 'h11b);
    wr(M + 'h234, 2);
    vector(A, A, D, 1, 'h20, 4, 4, 4, 1, 'h8000, 32'h90000000);
    for (int t = 0; t < 1000; t++) begin
      rd(M + 'h204, status);
      if (status[2]) break;
      if (t == 999) $fatal(1, "missing expected runtime fault");
    end
    expect_word(M + 'h08c, 120);
    expect_word(M + 'h280, 1);
    $display(
        "LAYOUT EVENTS PASS checks=%0d snapshots, zero/negative strides, final-only, keep-r2, packed stores, three-unit events, fault",
        checks);
    $finish;
  end
  initial begin
    #20000000;
    $fatal(1, "layout/events global timeout");
  end
endmodule
