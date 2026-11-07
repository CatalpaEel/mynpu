`timescale 1ns / 1ps
module tb_ops;
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
  int vectors = 0, gemms = 0;
  int av[256], bv[256];
  logic [31:0] aw[256], bw[256];
  task automatic gemm_case(input int m, n, k, flags);
    int bytes_per, ai, bi, want, seed, abytes, bbytes;
    bytes_per = (flags & 8) ? ((flags & 16) ? 2 : 1) : 4;
    abytes = m * k * bytes_per;
    bbytes = k * n * bytes_per;
    for (int j = 0; j < 256; j++) begin
      aw[j] = 0;
      bw[j] = 0;
    end
    for (int r = 0; r < m; r++)
      for (int t = 0; t < k; t++) begin
        seed = r * k + t;
        av[seed]=(flags&16) ? ((seed%3==0) ? -32768 : (seed%3==1) ? 32767 : seed*97-20000) : ((seed*17)%256)-128;
        ai = ((flags & 1) ? t * m + r : r * k + t) * bytes_per;
        aw[ai/4] |= (32'(av[seed]) & ((flags & 16) ? 32'hffff : 32'hff)) << ((ai % 4) * 8);
      end
    for (int t = 0; t < k; t++)
      for (int c = 0; c < n; c++) begin
        seed = t * n + c;
        bv[seed]=(flags&16) ? ((seed%3==0) ? -32768 : (seed%3==1) ? 32767 : seed*101-15000) : ((seed*29)%256)-128;
        bi = ((flags & 2) ? c * k + t : t * n + c) * bytes_per;
        bw[bi/4] |= (32'(bv[seed]) & ((flags & 16) ? 32'hffff : 32'hff)) << ((bi % 4) * 8);
      end
    for (int j = 0; j < (abytes + 3) / 4; j++) wr(SRAM + j * 4, aw[j]);
    for (int j = 0; j < (bbytes + 3) / 4; j++) wr(SRAM + 'h2000 + j * 4, bw[j]);
    for (int j = 0; j < m * n; j++) wr(SRAM + 'h1000 + j * 4, 32'h7ffffff0 + j);
    wr(SRAM + 'h1000 + m * n * 4, 32'hdeadbeef);
    wr(MMIO + 'h108, SRAM);
    wr(MMIO + 'h10c, SRAM + 'h2000);
    wr(MMIO + 'h110, SRAM + 'h1000);
    wr(MMIO + 'h114, m);
    wr(MMIO + 'h118, n);
    wr(MMIO + 'h11c, k);
    wr(MMIO + 'h130, flags);
    wr(MMIO + 'h100, 1);
    // Mutating shadow settings must not change active descriptor.
    wr(MMIO + 'h130, 31 - flags);
    wr(MMIO + 'h108, 0);
    wait_unit(MMIO + 'h104);
    for (int r = 0; r < m; r++)
      for (int c = 0; c < n; c++) begin
        want = (flags & 4) ? 32'h7ffffff0 + r * n + c : 0;
        for (int t = 0; t < k; t++) want += av[r*k+t] * bv[t*n+c];
        expect_word(SRAM + 'h1000 + (r * n + c) * 4, want);
      end
    expect_word(SRAM + 'h1000 + m * n * 4, 32'hdeadbeef);
    gemms++;
  endtask
  function automatic logic [31:0] ref_vec(input int op, input logic [31:0] a, b);
    longint signed sa, sb, magnitude, rounded, remainder, divisor;
    int shift_count;
    sa = $signed(a);
    sb = $signed(b);
    case (op)
      0: return sa < 0 ? 0 : a;
      1: return 32'(sa + sb);
      2: return a;
      3: return 32'(sa - sb);
      4: return sa < sb ? a : b;
      5: return sa > sb ? a : b;
      6: return a & b;
      7: return a | b;
      8: return a ^ b;
      9: return 32'({32'd0, a} << (b % 32));
      10: return 32'({32'd0, a} >> (b % 32));
      11: return 32'(sa >>> (b % 32));
      12: return a == b;
      13: return 32'(-sa);
      14: return 32'(sa < 0 ? -sa : sa);
      15: return a ^ 32'hffffffff;
      24: return 32'(sa * sb);
      25: return 32'(sa + sb);
      26: begin
        shift_count = int'(b & 63);
        if (shift_count == 0) return a;
        if (shift_count >= 33) return 0;
        magnitude = sa < 0 ? -sa : sa;
        divisor = 64'd1 << shift_count;
        rounded = magnitude / divisor;
        remainder = magnitude % divisor;
        if (remainder > divisor / 2 || remainder == divisor / 2 && rounded % 2 != 0) rounded++;
        return 32'(sa < 0 ? -rounded : rounded);
      end
    endcase
  endfunction
  logic [31:0] va[64], vb[64], wanted[64];
  task automatic vector_case(input int op, mode, inplace);
    logic [31:0] dest, scalar, randstate;
    dest = inplace == 1 ? SRAM + 'h1000 : inplace == 2 ? SRAM + 'h2400 : SRAM + 'h1800;
    scalar = 32'hffffffe1;
    randstate = 32'h12345678;
    for (int j = 0; j < 64; j++) begin
      randstate = randstate * 1664525 + 1013904223;
      va[j] = randstate;
      case (j % 8)
        0: vb[j] = 0;
        1: vb[j] = 31;
        2: vb[j] = 32;
        3: vb[j] = 255;
        4: vb[j] = 32'h80000000;
        default: vb[j] = ~randstate;
      endcase
      case (j)
        0: va[j] = 32'h80000000;
        1: va[j] = 32'h7fffffff;
        2: va[j] = 0;
        3: va[j] = 32'hffffffff;
      endcase
      wanted[j] = ref_vec(op, va[j], mode ? scalar : vb[j]);
      wr(SRAM + 'h1000 + j * 4, va[j]);
      wr(SRAM + 'h2400 + j * 4, vb[j]);
    end
    wr(dest + 256, 32'hcafef00d);
    wr(MMIO + 'h208, SRAM + 'h1000);
    wr(MMIO + 'h218, mode ? 0 : SRAM + 'h2400);
    wr(MMIO + 'h20c, dest);
    wr(MMIO + 'h210, 64);
    wr(MMIO + 'h214, op | (mode << 7));
    wr(MMIO + 'h230, scalar);
    wr(MMIO + 'h200, 1);
    wr(MMIO + 'h230, 0);
    wr(MMIO + 'h214, 0);
    wait_unit(MMIO + 'h204);
    for (int j = 0; j < 64; j++) expect_word(dest + j * 4, wanted[j]);
    expect_word(dest + 256, 32'hcafef00d);
    vectors++;
  endtask
  task automatic regfile_ops;
    logic [31:0] rf, cap, bank;
    rd(MMIO + 'h054, rf);
    rd(MMIO + 'h050, cap);
    bank = (cap & 65535) * 4;
    expect_word(MMIO + 'h054, 32'h80004000);
    for (int i = 0; i < 4; i++) begin
      wr(rf + 32'(i * 4), 32'((i + 1) * (i % 2 ? 1 : -1)));
      wr(rf + bank + 32'(i * 4), 32'((i + 5) * (i % 2 ? -1 : 1)));
    end
    wr(MMIO + 'h108, rf);
    wr(MMIO + 'h10c, rf + bank);
    wr(MMIO + 'h110, rf + 'h40);
    wr(MMIO + 'h114, 1);
    wr(MMIO + 'h118, 1);
    wr(MMIO + 'h11c, 4);
    wr(MMIO + 'h130, 0);
    wr(MMIO + 'h100, 1);
    wait_unit(MMIO + 'h104);
    expect_word(rf + 'h40, 32'(-70));
    gemms++;
    wr(MMIO + 'h208, rf + 'h40);
    wr(MMIO + 'h20c, rf + 'h80);
    wr(MMIO + 'h210, 1);
    wr(MMIO + 'h214, 129);
    wr(MMIO + 'h230, 5);
    wr(MMIO + 'h200, 1);
    wait_unit(MMIO + 'h204);
    expect_word(rf + 'h80, 32'(-65));
    vectors++;
    wr(SRAM + 'h1010, 32'h01000000);
    wr(SRAM + 'h1014, 0);
    wr(rf + 'h90, 32'ha5a5a5a5);
    wr(MMIO + 'h208, rf + 'h40);
    wr(MMIO + 'h218, SRAM + 'h1010);
    wr(MMIO + 'h20c, rf + 'h91);
    wr(MMIO + 'h234, 32'h208);
    wr(MMIO + 'h240, 32'h000040db);  // LD32 r2,[r1+4]
    wr(MMIO + 'h244, 32'h000000bb);  // LD32 r1,[r1]
    wr(MMIO + 'h248, 32'h00000218);  // MUL32 r0,r0,r1
    wr(MMIO + 'h24c, 32'h00000419);  // ADD64 r0,r0,r2
    wr(MMIO + 'h250, 32'h0001881a);  // RSHR64 r0,r0,24
    wr(MMIO + 'h254, 32'h00000601);  // ADD32 r0,r0,r3
    wr(MMIO + 'h258, 32'h00000805);  // MAX32 r0,r0,0
    wr(MMIO + 'h25c, 32'h000ff804);  // MIN32 r0,r0,255
    wr(MMIO + 'h214, 32'ha0);
    wr(MMIO + 'h230, 128);
    wr(MMIO + 'h200, 1);
    wait_unit(MMIO + 'h204);
    expect_word(rf + 'h90, 32'ha5a53aa5);
    vectors++;
    // DMA must distinguish RF and SRAM address spaces when checking aliases.
    wr(SRAM + 'h1000, 32'h44332211);
    wr(SRAM + 'h1004, 32'h88776655);
    wr(rf + 'hc4, 32'ha5a5a5a5);
    wr(MMIO + 'h508, SRAM + 'h1000);
    wr(MMIO + 'h50c, rf + 'hc0);
    wr(MMIO + 'h510, 7);
    wr(MMIO + 'h514, 1);
    wr(MMIO + 'h518, 0);
    wr(MMIO + 'h51c, 0);
    wr(MMIO + 'h520, 2);
    wr(MMIO + 'h500, 1);
    wait_unit(MMIO + 'h504);
    expect_word(rf + 'hc0, 32'h44332211);
    expect_word(rf + 'hc4, 32'ha5776655);
    wr(SRAM + 'h1104, 32'ha5a5a5a5);
    wr(MMIO + 'h508, rf + 'hc0);
    wr(MMIO + 'h50c, SRAM + 'h1100);
    wr(MMIO + 'h500, 1);
    wait_unit(MMIO + 'h504);
    expect_word(SRAM + 'h1100, 32'h44332211);
    expect_word(SRAM + 'h1104, 32'ha5776655);
    $display("REGFILE OPERATORS PASS GEMM, vector, software vector program, DMA SRAM/RF copies");
  endtask
  initial begin
    repeat (5) @(negedge clk);
    rst_n = 1;
    expect_word(MMIO + 'h040, 32'h10001);
    expect_word(MMIO + 'h044, 31);
    expect_word(MMIO + 'h05c, 32'h00030820);
    expect_word(MMIO + 'h048, 32'h0700ffff);
    expect_word(MMIO + 'h04c, 15);
    for (int flags = 0; flags < 32; flags++) begin
      gemm_case(3, 5, 7, flags);
      gemm_case(1, 1, 1, flags);
    end
    gemm_case(16, 16, 16, 31);
    gemm_case(16, 16, 16, 0);
    for (int op = 0; op < 16; op++)
    for (int mode = 0; mode < 2; mode++)
    for (int inplace = 0; inplace < 3; inplace++) vector_case(op, mode, inplace);
    // A packed four-byte row fits at the last SRAM word; a fifth byte does not.
    wr(SRAM + 'h3ffc, 32'h04030201);
    wr(SRAM + 'h2000, 32'h01010101);
    wr(MMIO + 'h108, SRAM + 'h3ffc);
    wr(MMIO + 'h10c, SRAM + 'h2000);
    wr(MMIO + 'h110, SRAM + 'h1000);
    wr(MMIO + 'h114, 1);
    wr(MMIO + 'h118, 1);
    wr(MMIO + 'h11c, 4);
    wr(MMIO + 'h130, 8);
    wr(MMIO + 'h100, 1);
    wait_unit(MMIO + 'h104);
    expect_word(SRAM + 'h1000, 10);
    gemms++;
    wr(MMIO + 'h11c, 5);
    wr(MMIO + 'h100, 1);
    expect_word(MMIO + 'h104, 4);
    expect_word(SRAM + 'h1000, 10);
    // Partial overlap remains illegal, even for COPY. Exact alias was tested above.
    wr(MMIO + 'h208, SRAM + 'h1000);
    wr(MMIO + 'h20c, SRAM + 'h1004);
    wr(MMIO + 'h210, 4);
    wr(MMIO + 'h214, 2);
    wr(MMIO + 'h200, 1);
    expect_word(MMIO + 'h204, 4);
    // Reserved descriptors must not enter either queue or modify destination.
    wr(MMIO + 'h130, 32);
    wr(MMIO + 'h108, SRAM);
    wr(MMIO + 'h100, 1);
    expect_word(MMIO + 'h104, 4);
    expect_word(MMIO + 'h12c, gemms);
    wr(MMIO + 'h214, 17);
    wr(MMIO + 'h200, 1);
    expect_word(MMIO + 'h204, 4);
    expect_word(MMIO + 'h22c, vectors);
    for (int op = 24; op <= 26; op++)
    for (int mode = 0; mode < 2; mode++)
    for (int inplace = 0; inplace < 3; inplace++) vector_case(op, mode, inplace);
    regfile_ops();
    $display("OPERATORS PASS gemm_jobs=%0d vector_jobs=%0d checks=%0d", gemms, vectors, checks);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "operators timeout");
  end
endmodule
