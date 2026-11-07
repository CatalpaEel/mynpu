`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_shared_operands;
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
        wr('h40000618, 'h800040e0);
        wr('h4000061c, 1);
        wr('h40000620, 1);
        wr('h40000624, 1);
        wr('h4000062c, 0);
        wr('h40000630, 0);
        wr('h40000628, (1 << 14) | (2 << 18) | (1 << 21) | (1 << 22));
      end
      1: begin
        wr(MATRIX_B, 32'(multiplier));
        wr('h40000108, src);
        wr('h4000010c, MATRIX_B);
        wr('h40000110, dst);
        wr('h40000114, 1);
        wr('h40000118, 1);
        wr('h4000011c, 1);
        wr('h40000130, 0);
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

  int matrix_busy_cycles = 0, vector_busy_cycles = 0;
  int both_request = 0;
  int matrix_terms = 0, matrix_parallel_reads = 0, vector_parallel_reads = 0;
  always @(posedge clk)
    if (rst_n) begin
      if (dut.i_core.mat_busy) matrix_busy_cycles++;
      if (dut.i_core.vec_busy) vector_busy_cycles++;
      if ((|dut.i_core.all_gather_req[5:3]) && (|dut.i_core.all_gather_req[8:6])) both_request++;
      if (dut.i_core.matrix_compute_valid && dut.i_core.matrix_compute_ready && dut.i_core.matrix_compute_multiply)
        matrix_terms += $countones(
            dut.i_core.matrix_row_mask
        ) * $countones(
            dut.i_core.matrix_col_mask
        );

      if ($countones(dut.i_core.all_gather_gnt[5:3]) >= 2) matrix_parallel_reads++;
      if ($countones(dut.i_core.all_gather_gnt[8:6]) >= 2) vector_parallel_reads++;
    end
  task automatic gemm(input int flags, kinds, offset);
    logic [31:0] a, b, d, got;
    logic [31:0] aw[32], bw[32];
    int av[14], bv[21];
    int size, index, expected, shift;
    a = kinds[0] ? 'h80004000 : 'h80001000;
    b = kinds[1] ? 'h80004040 : 'h80002000;
    d = 'h800040a0;
    size = flags[3] ? (flags[4] ? 2 : 1) : 4;
    if (flags[3]) begin
      a += offset * 4;
      b += offset * 4;
    end
    for (int j = 0; j < 32; j++) begin
      aw[j] = 0;
      bw[j] = 0;
    end
    for (int j = 0; j < 14; j++) begin
      av[j] = flags[4] ? j * 4093 - 29000 : j - 7;
      index = (a[1:0] + j * size) / 4;
      shift = ((a[1:0] + j * size) % 4) * 8;
      aw[index] |= (32'(av[j]) & (flags[4] ? 'hffff : 'hff)) << shift;
    end
    for (int j = 0; j < 21; j++) begin
      bv[j] = flags[4] ? j * 1877 - 16000 : j % 13 - 6;
      index = (b[1:0] + j * size) / 4;
      shift = ((b[1:0] + j * size) % 4) * 8;
      bw[index] |= (32'(bv[j]) & (flags[4] ? 'hffff : 'hff)) << shift;
    end
    for (int j = 0; j < (a[1:0] + 14 * size + 3) / 4; j++) wr({a[31:2], 2'b0} + 4 * j, aw[j]);
    for (int j = 0; j < (b[1:0] + 21 * size + 3) / 4; j++) wr({b[31:2], 2'b0} + 4 * j, bw[j]);
    for (int j = 0; j < 6; j++) wr(d + 4 * j, 32'(j - 77));
    wr('h40000108, a);
    wr('h4000010c, b);
    wr('h40000110, d);
    wr('h40000114, 2);
    wr('h40000118, 3);
    wr('h4000011c, 7);
    wr('h40000130, 32'(flags));
    start(1);
    wait_done(1);
    for (int i = 0; i < 2; i++)
      for (int j = 0; j < 3; j++) begin
        expected = flags[2] ? i * 3 + j - 77 : 0;
        for (int k = 0; k < 7; k++)
        expected += av[flags[0] ? k * 2 + i : i * 7 + k] * bv[flags[1] ? j * 7 + k : k * 3 + j];
        rd(d + 4 * (i * 3 + j), got);
        if (got !== 32'(expected))
          $fatal(
              1,
              "GEMM flags=%0d kinds=%0d offset=%0d i=%0d j=%0d got=%h want=%h",
              flags,
              kinds,
              offset,
              i,
              j,
              got,
              expected
          );
        checks++;
      end
  endtask
  function automatic int light(input int op, a, b);
    case (op)
      0: return a < 0 ? 0 : a;
      1: return a + b;
      2: return a;
      3: return a - b;
      4: return a < b ? a : b;
      5: return a > b ? a : b;
      6: return a & b;
      7: return a | b;
      8: return a ^ b;
      9: return a << b[4:0];
      10: return unsigned'(a) >> b[4:0];
      11: return a >>> b[4:0];
      12: return a == b;
      13: return -a;
      14: return a < 0 ? -a : a;
      15: return ~a;
    endcase
  endfunction
  task automatic vector_case(input int op, len, kind, inplace);
    logic [31:0] a, d, got;
    int value, expected;
    a = kind ? 'h80004000 : 'h80001000;
    d = inplace ? a : (kind ? 'h80004080 : 'h80001800);
    for (int i = 0; i < len; i++) wr(a + 4 * i, 32'((i - 4) * 1234567));
    wr('h40000208, a);
    wr('h40000218, 0);
    wr('h4000020c, d);
    wr('h40000210, 32'(len));
    wr('h40000214, 32'(op | 'h80));
    wr('h40000230, 3);
    start(2);
    wait_done(2);
    for (int i = 0; i < len; i++) begin
      value = (i - 4) * 1234567;
      expected = light(op, value, 3);
      rd(d + 4 * i, got);
      if (got !== 32'(expected))
        $fatal(1, "VECTOR op=%0d len=%0d i=%0d got=%h want=%h", op, len, i, got, expected);
      checks++;
    end
  endtask
  task automatic binary_case(input int op, kinds, same);
    logic [31:0] a, b, d, got;
    int av, bv, expected;
    longint signed wide;
    a = kinds[0] ? 'h80004000 : 'h80001000;
    b = same ? a : (kinds[1] ? 'h80004040 : 'h80002000);
    d = 'h80001800;
    for (int i = 0; i < 8; i++) begin
      wr(a + 4 * i, 32'((i - 4) * 117));
      if (!same) wr(b + 4 * i, 32'(i + 1));
    end
    wr('h40000208, a);
    wr('h40000218, b);
    wr('h4000020c, d);
    wr('h40000210, 8);
    wr('h40000214, 32'(op));
    wr('h40000230, 0);
    start(2);
    wait_done(2);
    for (int i = 0; i < 8; i++) begin
      av = (i - 4) * 117;
      bv = same ? av : i + 1;
      if (op < 16) expected = light(op, av, bv);
      else if (op == 24) expected = av * bv;
      else begin
        wide = longint'(av) * longint'(bv);
        wide = wide >>> 32;
        expected = 32'(wide);
      end
      rd(d + 4 * i, got);
      if (got !== 32'(expected))
        $fatal(
            1,
            "Binary vector op=%0d kinds=%0d same=%0d i=%0d got=%h want=%h",
            op,
            kinds,
            same,
            i,
            got,
            expected
        );
      checks++;
    end
  endtask
  initial begin
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    for (int flags = 0; flags < 32; flags++)
    for (int kinds = 0; kinds < 4; kinds++)
    for (int offset = 0; offset < 2; offset++) gemm(flags, kinds, offset);
    for (int op = 0; op < 16; op++)
    for (int kind = 0; kind < 2; kind++)
    for (int inplace = 0; inplace < 2; inplace++) begin
      vector_case(op, 1, kind, inplace);
      vector_case(op, 2, kind, inplace);
      vector_case(op, 3, kind, inplace);
      vector_case(op, 9, kind, inplace);
    end
    if (matrix_terms != 256 * 42 || (dut.i_core.PARALLEL_UNITS && (matrix_parallel_reads == 0)))
      $fatal(
          1,
          "Parallel paths not exercised terms=%0d mreads=%0d vreads=%0d",
          matrix_terms,
          matrix_parallel_reads,
          vector_parallel_reads
      );
    $display("SHARED BENCH parallel=%0d matrix_busy=%0d vector_busy=%0d",
             dut.i_core.PARALLEL_UNITS, matrix_busy_cycles, vector_busy_cycles);
    for (int op = 1; op <= 25; op++)
    if (op <= 12 || op == 24 || op == 20)
      for (int kinds = 0; kinds < 4; kinds++)
      for (int same = 0; same < 2; same++) binary_case(op, kinds, same);
    // Both units contend for the same RF banks while remaining independent.
    for (int i = 0; i < 16; i++) begin
      wr('h80004000 + 4 * i, 32'(i + 1));
      wr('h80004040 + 4 * i, 2);
      wr('h80004080 + 4 * i, 32'(i - 8));
    end
    wr('h40000108, 'h80004000);
    wr('h4000010c, 'h80004040);
    wr('h40000110, 'h80001880);
    wr('h40000114, 1);
    wr('h40000118, 1);
    wr('h4000011c, 16);
    wr('h40000130, 0);
    wr('h40000208, 'h80004080);
    wr('h4000020c, 'h80001800);
    wr('h40000210, 16);
    wr('h40000214, 'h81);
    wr('h40000230, 3);
    for (int phase = 0; phase < 6; phase++) begin
      start(2);
      repeat (phase) @(negedge clk);
      start(1);
      wait_done(1);
      wait_done(2);
    end
    begin
      logic [31:0] got;
      rd('h80001880, got);
      if (got !== 272) $fatal(1, "Concurrent GEMM");
      for (int i = 0; i < 16; i++) begin
        rd('h80001800 + 4 * i, got);
        if (got !== 32'(i - 5)) $fatal(1, "Concurrent vector");
      end
      checks += 17;
    end
    if (dut.i_core.PARALLEL_UNITS && both_request == 0)
      $fatal(1, "Concurrent gather not exercised");
    $display(
        "SHARED OPERANDS PASS checks=%0d matrix_terms=%0d matrix_parallel_reads=%0d vector_parallel_reads=%0d",
        checks, matrix_terms, matrix_parallel_reads, vector_parallel_reads);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "timeout");
  end
endmodule
