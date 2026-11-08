`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_software_config;
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
      if (cycles > 1000) $fatal(1, "host grant timeout %h", a);
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
  localparam logic [31:0] M='h40000000, S0='h80006000, S1='h80006100, S2='h80006200, S3='h80006300;
  task automatic restart;
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
  endtask
  task automatic expect_word(input logic [31:0] a, v);
    logic [31:0] got;
    rd(a, got);
    if (got !== v) $fatal(1, "software-config addr=%h got=%h expected=%h", a, got, v);
    checks++;
  endtask
  task automatic queue_started(input int page);
    logic [31:0] q;
    for (int i = 0; i < 1000; i++) begin
      rd(M + 32'(page) + (page == 'h600 ? 'h58 : 'h24), q);
      if (q[15:0] == 0) return;
    end
    $fatal(1, "task did not dispatch");
  endtask
  task automatic finish_unit(input int page, input int count);
    logic [31:0] status, completed;
    for (int i = 0; i < 5000; i++) begin
      rd(M + 32'(page) + 4, status);
      if (status[2]) $fatal(1, "unit fault page=%h status=%h", page, status);
      rd(M + 32'(page) + (page == 'h600 ? 'h5c : 'h28), completed);
      if (!status[0] && completed == 32'(count)) return;
    end
    $fatal(1, "unit failed to complete page=%h count=%0d", page, count);
  endtask
  task automatic kernel(input logic [31:0] address, input int weight);
    wr(address, 0);
    wr(address + 4, 32'(weight));
    wr(address + 8, 0);
  endtask
  task automatic matrix_one(input logic [31:0] source);
    wr('h80002000, 2);
    wr(M + 'h108, source);
    wr(M + 'h10c, 'h80002000);
    wr(M + 'h110, 'h80001900);
    wr(M + 'h114, 1);
    wr(M + 'h118, 1);
    wr(M + 'h11c, 1);
    wr(M + 'h130, 0);
    wr(M + 'h134, 0);
    wr(M + 'h138, 0);
    wr(M + 'h13c, 0);
    wr(M + 'h140, 4);
    wr(M + 'h100, 1);
  endtask
  task automatic quant_setup(input int mode, mul, bias, zero, input logic [31:0] dst);
    wr(M + 'h740, 0);
    wr(M + 'h744, 32'(mul));
    wr(M + 'h748, 32'(bias));
    wr(M + 'h74c, 0);
    wr(M + 'h750, 32'(zero));
    wr(M + 'h754, 0);
    wr(M + 'h758, 'h7fffffff);
    wr(M + 'h75c, 0);
    wr(M + 'h760, dst);
    wr(M + 'h740, 32'(mode));
  endtask
  initial begin
    logic [31:0] status;
    restart();
    expect_word(M + 'h080, 'hf);
    // Active CNN geometry is latched; queued geometry is intentionally late-bound.
    kernel('h80002000, 2);
    kernel('h80002020, 3);
    wr('h80001400, 9);
    wr('h80001800, 'hdeadbeef);
    wr('h80001810, 'hdeadbeef);
    wr(M + 'h608, S0);
    wr(M + 'h60c, 'h80002000);
    wr(M + 'h610, 'h80001800);
    wr(M + 'h614, 1);
    wr(M + 'h618, 'h800040f0);
    wr(M + 'h61c, 1);
    wr(M + 'h620, 1);
    wr(M + 'h624, 1);
    wr(M + 'h62c, 0);
    wr(M + 'h628, npu_stream_pkg::encode_task(0, 0, 1, 2, 1, 1, 0));
    wr(M + 'h600, 1);
    queue_started('h600);
    wr(M + 'h600, 1);
    rd(M + 'h604, status);
    if (!status[0]) $fatal(1, "CNN not active for runtime writes");
    wr(M + 'h608, 'h80001400);
    wr(M + 'h60c, 'h80002020);
    wr(M + 'h610, 'h80001810);
    expect_word(M + 'h658, 'h00080001);
    wr(S0, 6);
    finish_unit('h600, 2);
    expect_word('h80001800, 12);
    expect_word('h80001810, 27);
    $display("SOFTWARE CONFIG CNN PASS active-old/queued-new/nonempty-FIFO/runtime-writes");

    restart();
    // Program count is latched per job; instruction words are read live.
    wr(M + 'h208, S1);
    wr(M + 'h218, 0);
    wr(M + 'h20c, 'h80001800);
    wr(M + 'h210, 1);
    wr(M + 'h214, 'h20);
    wr(M + 'h234, 1);
    wr(M + 'h240, 2);
    wr(M + 'h200, 1);
    queue_started('h200);
    wr(M + 'h20c, 'h80001810);
    wr(M + 'h200, 1);
    wr(M + 'h234, 2);
    wr(M + 'h240, (7 << 12) | (1 << 5) | 1);
    wr(M + 'h244, (2 << 12) | (1 << 5) | 24);
    expect_word(M + 'h224, 'h00080001);
    wr(S1, 5);
    wr(S1, 6);
    finish_unit('h200, 2);
    expect_word('h80001800, 12);
    expect_word('h80001810, 26);
    $display("SOFTWARE CONFIG VECTOR PASS active-program-live/count-latched/queued-count-new");

    restart();
    // A pending Matrix result sees parameters changed before quant accepts it.
    wr('h80001a00, 'hdeadbeef);
    wr('h80001a04, 'hdeadbeef);
    quant_setup(3, 3, 0, 0, 'h80001a00);
    matrix_one(S2);
    queue_started('h100);
    rd(M + 'h104, status);
    if (!status[0]) $fatal(1, "Matrix not active for quant writes");
    wr(M + 'h744, 4);
    wr(M + 'h748, 1);
    wr(M + 'h750, 2);
    wr(M + 'h760, 'h80001a04);
    wr(S2, 6);
    finish_unit('h100, 1);
    expect_word('h80001a00, 'hdeadbeef);
    expect_word('h80001a04, 'hdeadbe33);
    $display("SOFTWARE CONFIG QUANT PASS active-source/pre-accept-parameters/new-destination");

    restart();
    // Arithmetic already in flight stays latched; destination remains live.
    quant_setup(1, 3, 0, 0, S3);
    wr('h80001400, 6);
    for (int i = 0; i < 16; i++) wr(S3, 'hface0000 + 32'(i));
    matrix_one('h80001400);
    for (int i = 0; i < 1000; i++) begin
      @(negedge clk);
      if (dut.i_core.quant_out_valid[1] && !dut.i_core.quant_out_ready[1]) break;
      if (i == 999) $fatal(1, "quant result did not reach backpressure");
    end
    wr(M + 'h744, 9);
    wr(M + 'h748, 7);
    wr(M + 'h750, 5);
    wr(M + 'h760, 'h80001a00);
    finish_unit('h100, 1);
    expect_word('h80001a00, 36);
    for (int i = 0; i < 16; i++) expect_word(S3, 'hface0000 + 32'(i));
    matrix_one('h80001400);
    finish_unit('h100, 2);
    expect_word('h80001a00, 120);
    $display(
        "SOFTWARE CONFIG QUANT INFLIGHT PASS arithmetic-latched/destination-live/FIFO-unchanged/next-result-new");
    $display(
        "SOFTWARE CONFIG PASS checks=%0d CNN/Matrix/Vector/quant runtime ownership and sampling boundaries",
        checks);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "software config timeout");
  end
endmodule
