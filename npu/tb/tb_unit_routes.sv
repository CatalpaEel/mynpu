`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_unit_routes;
  logic clk = 0, rst_n = 0;
  always #10 clk = ~clk;
  logic tck = 0, tms = 1, tdi = 0;
  wire tdo;
  `include "db_jtag_tasks.svh"
  `include "db_sba_access.svh"
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b0),
    .tck_i             (tck),
    .tms_i             (tms),
    .td_i              (tdi),
    .td_o              (tdo),
    .cpu_debug_halted_o(),
    .irq_o             (),
    .cpu_test_done_o   (),
    .cpu_test_pass_o   ()
  );
  int checks = 0;
  localparam logic [31:0] INPUT_A=32'h80001400, OUTPUT_D=32'h80001700,
    WEIGHTS=32'h80002000, MATRIX_B=32'h80002020, CHANNEL=32'h80006000;
  task automatic bus(input bit we, input logic [31:0] a, d, output logic [31:0] result);
    sba_access(we, a, d, 4'hf, 0, result);
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    bus(1, a, d, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    bus(0, a, 0, d);
  endtask
  // id: 0 CNN, 1 Matrix, 2 Vector. Consumer multiplies by 3; producer by 2.
  task automatic configure(input int id, input logic [31:0] src, dst, input int multiplier);
    case (id)
      0: begin
        wr(WEIGHTS, 0);
        wr(WEIGHTS + 4, 32'(multiplier));
        wr(WEIGHTS + 8, 0);
        wr('h40000608, src);
        wr('h4000060c, WEIGHTS);
        wr('h40000610, dst);
        wr('h40000614, 1);
        wr('h40000618, 'h800040c0);
        wr('h4000061c, 1);
        wr('h40000620, 1);
        wr('h40000624, 1);
        wr('h4000062c, 0);
        wr('h40000630, 0);
        wr('h40000628, (0 << 0) | (2 << 4) | (1 << 7) | (1 << 8));
      end
      1: begin
        wr(MATRIX_B, 32'(multiplier));
        wr('h40000108, src);
        wr('h4000010c, MATRIX_B);
        wr('h40000110, dst);
        wr('h40000114, 1);
        wr('h40000118, 1);
        wr('h4000011c, 1);
        matrix_config(0);
      end
      2: begin
        wr('h40000208, src);
        wr('h40000218, 0);
        wr('h4000020c, dst);
        wr('h40000210, 1);
        wr('h40000214, 'h98);
        wr('h40000230, 32'(multiplier));
      end
    endcase
  endtask
  task automatic start(input int id);
    wr('h40000000 + (id == 0 ? 'h600 : id == 1 ? 'h100 : 'h200), 1);
  endtask
  task automatic wait_done(input int id);
    logic [31:0] status;
    for (int k = 0; k < 1000; k++) begin
      rd('h40000004 + (id == 0 ? 'h600 : id == 1 ? 'h100 : 'h200), status);
      if (status[2]) $fatal(1, "engine fault id=%0d", id);
      if (status[1] && !status[0]) return;
    end
    $fatal(1, "route deadlock id=%0d", id);
  endtask
  // Translate the regression oracle's old layout tuple into explicit MMIO fields.
  task automatic matrix_config(input logic [31:0] f);
    wr('h4000013c, {31'b0, f[4]});
    wr('h40000140, f[3] ? (f[4] ? 2 : 1) : 4);
    wr('h40000130, f <= 31 ? (f & 7) : f);
  endtask
  initial begin
    logic [31:0] result;
    for (int producer = 0; producer < 3; producer++)
    for (int consumer = 0; consumer < 3; consumer++)
    if (producer != consumer) begin
      @(negedge clk);
      rst_n = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      repeat (8) @(negedge clk);
      wr(INPUT_A, 6);
      wr(OUTPUT_D, 'hdeadbeef);
      configure(consumer, CHANNEL, OUTPUT_D, 3);
      configure(producer, INPUT_A, CHANNEL, 2);
      start(consumer);  // waits on empty channel without blocking producer access
      repeat (30) @(negedge clk);
      start(producer);
      wait_done(producer);
      wait_done(consumer);
      rd(OUTPUT_D, result);
      if (result !== 36) $fatal(1, "route %0d -> %0d got=%h want=36", producer, consumer, result);
      checks++;
      $display("UNIT ROUTE producer=%0d consumer=%0d PASS", producer, consumer);
    end
    // A three-stage chain runs concurrently on two independent channels.
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    wr(INPUT_A, 6);
    wr(OUTPUT_D, 0);
    configure(1, CHANNEL + 256, OUTPUT_D, 3);
    configure(2, CHANNEL, CHANNEL + 256, 2);
    configure(0, INPUT_A, CHANNEL, 2);
    start(1);
    start(2);
    start(0);
    wait_done(0);
    wait_done(2);
    wait_done(1);
    rd(OUTPUT_D, result);
    if (result !== 72) $fatal(1, "three-stage chain got=%h", result);
    checks++;
    // 256 elements cross the endpoint cursor wrap, with backpressure from GEMM.
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    for (int group = 0; group < 4; group++)
    for (int k = 0; k < 16; k++)
    for (int row = 0; row < 4; row++)
    wr(INPUT_A + 4 * (group * 64 + k * 4 + row), 32'(((group * 4 + row) * 16 + k) % 7 + 1));
    configure(1, CHANNEL, 'h80001800, 3);
    for (int k = 0; k < 16; k++) wr(MATRIX_B + 4 * k, 3);
    wr('h40000114, 16);
    wr('h4000011c, 16);
    configure(2, INPUT_A, CHANNEL, 2);
    wr('h40000210, 256);
    start(1);
    start(2);
    wait_done(2);
    wait_done(1);
    for (int row = 0; row < 16; row++) begin
      int expected;
      expected = 0;
      for (int k = 0; k < 16; k++) expected += 6 * ((row * 16 + k) % 7 + 1);
      rd('h80001800 + 4 * row, result);
      if (result !== 32'(expected))
        $fatal(1, "multiword route row=%0d got=%h want=%0d", row, result, expected);
      checks++;
    end
    // CNN weights may also be an ordered stream: three words carry a DOT9.
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    wr(INPUT_A, 6);
    wr(OUTPUT_D, 0);
    configure(0, INPUT_A, OUTPUT_D, 3);
    wr('h4000060c, CHANNEL);
    configure(2, WEIGHTS, CHANNEL, 1);
    wr('h40000214, 2);
    wr('h40000210, 3);
    start(0);
    start(2);
    wait_done(2);
    wait_done(0);
    rd(OUTPUT_D, result);
    if (result !== 18) $fatal(1, "streamed DOT9 weights got=%h", result);
    checks++;
    $display(
        "UNIT ROUTES PASS checks=%0d six directed pairs, three-stage chain, 256-word GEMM, streamed DOT9 weights",
        checks);
    $finish;
  end
endmodule
