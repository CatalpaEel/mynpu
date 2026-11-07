`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_outer_gemm;
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
    for (int k = 0; k < 30000; k++) begin
      rd('h40000004 + (id == 0 ? 'h600 : id == 1 ? 'h100 : 'h200), status);
      if (status[2]) $fatal(1, "engine fault id=%0d", id);
      if (status[1] && !status[0]) return;
    end
    $fatal(1, "route deadlock id=%0d", id);
  endtask

  int mac_count = 0, full_steps = 0;
  always @(posedge clk)
    if(rst_n && dut.i_core.matrix_compute_valid && dut.i_core.matrix_compute_ready && dut.i_core.matrix_compute_multiply)begin
      mac_count += $countones(dut.i_core.matrix_row_mask) * $countones(dut.i_core.matrix_col_mask);
      if (dut.i_core.matrix_row_mask == 15 && dut.i_core.matrix_col_mask == 15) full_steps++;
    end
  task automatic gemm_case(input int m, n, k, flags, padded, kinds, seed);
    int lda, ldb, aspan, bspan, size, before_macs, expected;
    int av[512], bv[512];
    logic [31:0] aw[512], bw[512], a, b, d, got, mask;
    a = kinds[0] ? 'h80004000 : 'h80001000;
    b = kinds[1] ? 'h80004080 : 'h80002000;
    d = 'h80001800;
    lda = (flags[0] ? m : k) + padded * 3;
    ldb = (flags[1] ? k : n) + padded * 3;
    aspan = ((flags[0] ? k : m) - 1) * lda + (flags[0] ? m : k);
    bspan = ((flags[1] ? n : k) - 1) * ldb + (flags[1] ? k : n);
    size = flags[3] ? (flags[4] ? 2 : 1) : 4;
    mask = flags[4] ? 'hffff : 'hff;
    for (int w = 0; w < 512; w++) begin
      aw[w] = 0;
      bw[w] = 0;
    end
    for (int x = 0; x < aspan; x++) begin
      av[x]=flags[4] ? ((x*4093+seed*13)%65536)-32768:((x*17+seed*13)%256)-128;
      aw[x*size/4] |= (32'(av[x]) & mask) << ((x * size % 4) * 8);
    end
    for (int x = 0; x < bspan; x++) begin
      bv[x]=flags[4] ? ((x*1877+seed*7)%65536)-32768:((x*11+seed*7)%256)-128;
      bw[x*size/4] |= (32'(bv[x]) & mask) << ((x * size % 4) * 8);
    end
    for (int w = 0; w < (aspan * size + 3) / 4; w++) wr(a + 4 * w, aw[w]);
    for (int w = 0; w < (bspan * size + 3) / 4; w++) wr(b + 4 * w, bw[w]);
    for (int x = 0; x < m * n; x++) wr(d + 4 * x, 32'('h7ffffff0 + x));
    wr(d + 4 * m * n, 'hdeadbeef);
    wr('h40000134, padded ? 32'(lda) : 0);
    wr('h40000138, padded ? 32'(ldb) : 0);
    wr('h40000108, a);
    wr('h4000010c, b);
    wr('h40000110, d);
    wr('h40000114, 32'(m));
    wr('h40000118, 32'(n));
    wr('h4000011c, 32'(k));
    wr('h40000130, 32'(flags));
    before_macs = mac_count;
    start(1);
    wait_done(1);
    if (mac_count - before_macs != m * n * k)
      $fatal(
          1,
          "MAC count flags=%0d shape=%0d,%0d,%0d count=%0d",
          flags,
          m,
          n,
          k,
          mac_count - before_macs
      );
    for (int i = 0; i < m; i++)
      for (int j = 0; j < n; j++) begin
        expected = flags[2] ? 'h7ffffff0 + i * n + j : 0;
        for (int t = 0; t < k; t++)
        expected+=32'(longint'(av[flags[0] ? t*lda+i:i*lda+t])*longint'(bv[flags[1] ? j*ldb+t:t*ldb+j]));
        rd(d + 4 * (i * n + j), got);
        if (got !== 32'(expected))
          $fatal(
              1,
              "outer GEMM flags=%0d pad=%0d kind=%0d shape=%0d,%0d,%0d i=%0d j=%0d got=%h expected=%h",
              flags,
              padded,
              kinds,
              m,
              n,
              k,
              i,
              j,
              got,
              expected
          );
        checks++;
      end
    rd(d + 4 * m * n, got);
    if (got !== 'hdeadbeef) $fatal(1, "tail overwrite");
    checks++;
  endtask
  initial begin
    logic [31:0] got;
    int ms[7] = '{1, 4, 5, 8, 9, 16, 3};
    int ns[7] = '{1, 4, 7, 8, 5, 16, 2};
    int ks[7] = '{1, 4, 3, 7, 16, 16, 7};
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    rd('h4000006c, got);
    if (got !== 'h00030404) $fatal(1, "outer capability %h", got);
    for (int flags = 0; flags < 32; flags++)
    for (int pad = 0; pad < 2; pad++)
    for (int shape = 0; shape < 7; shape++)
    gemm_case(ms[shape], ns[shape], ks[shape], flags, pad, 0, flags + shape);
    for (int flags = 0; flags < 32; flags++)
    for (int kinds = 0; kinds < 4; kinds++) gemm_case(4, 4, 4, flags, 1, kinds, flags + kinds);
    // Multi-tile optional quant8: 3 * 3 / 2 rounds 4.5 to even4, plus zero2.
    wr('h40000744, 3);
    wr('h40000748, 0);
    wr('h4000074c, 1);
    wr('h40000750, 2);
    wr('h40000754, 0);
    wr('h40000758, 255);
    wr('h4000075c, 0);
    wr('h40000760, 'h80001901);
    wr('h40000740, 3);
    for (int w = 0; w < 4; w++) wr('h80001000 + 4 * w, 'h01010101);
    for (int w = 0; w < 6; w++) wr('h80002000 + 4 * w, 'h01010101);
    for (int w = 0; w < 10; w++) wr('h80001900 + 4 * w, 'ha5a5a5a5);
    wr('h40000134, 0);
    wr('h40000138, 0);
    wr('h40000108, 'h80001000);
    wr('h4000010c, 'h80002000);
    wr('h40000110, 'h80001800);
    wr('h40000114, 5);
    wr('h40000118, 7);
    wr('h4000011c, 3);
    wr('h40000130, 8);
    start(1);
    wait_done(1);
    for (int w = 0; w < 10; w++) begin
      rd('h80001900 + 4 * w, got);
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        if(got[byte_index*8+:8] !== (w*4+byte_index>=1 && w*4+byte_index<=35 ? 8'd6:8'ha5))
          $fatal(1, "quant tile address/tail got=%h", got);
        checks++;
      end
    end
    wr('h40000740, 0);
    // K=0, beta=1 exports the completed raw D without any operand access.
    wr('h40000134, 0);
    wr('h40000138, 0);
    wr('h40000114, 1);
    wr('h40000118, 1);
    wr('h4000011c, 0);
    wr('h40000130, 4);
    wr('h80001800, 'h81234567);
    wr('h40000110, 'h80001800);
    wr('h40000108, 0);
    wr('h4000010c, 0);
    start(1);
    wait_done(1);
    rd('h80001800, got);
    if (got !== 'h81234567) $fatal(1, "K0 export changed D");
    checks++;
    // Quant32's stream destination also preserves row-major FIFO order.
    wr('h40000744, 1);
    wr('h40000748, 0);
    wr('h4000074c, 0);
    wr('h40000750, 0);
    wr('h40000754, 0);
    wr('h40000758, 255);
    wr('h4000075c, 0);
    wr('h40000760, CHANNEL);
    wr('h40000740, 1);
    for (int r = 0; r < 5; r++) wr('h80001000 + 4 * r, 32'(r + 1));
    for (int c = 0; c < 7; c++) wr('h80002000 + 4 * c, 32'(c + 1));
    wr('h40000108, 'h80001000);
    wr('h4000010c, 'h80002000);
    wr('h40000110, 'h80001800);
    wr('h40000114, 5);
    wr('h40000118, 7);
    wr('h4000011c, 1);
    wr('h40000130, 0);
    start(1);
    for (int i = 0; i < 35; i++) begin
      rd(CHANNEL, got);
      if (got !== 32'((i / 7 + 1) * (i % 7 + 1)))
        $fatal(1, "quant32 FIFO row order element=%0d got=%h", i, got);
      checks++;
    end
    wait_done(1);
    wr('h40000740, 0);
    if (full_steps < 1000) $fatal(1, "full 4x4 not exercised");
    $display(
        "OUTER GEMM PASS checks=%0d macs=%0d full_steps=%0d flags/strides/tails/tiles/SRAM/RF/K0",
        checks, mac_count, full_steps);
    $finish;
  end
endmodule
