`timescale 1ns / 1ps
module tb_mnist;
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
      if (waited > 16) $fatal(1, "Host starved, addr=%h", a);
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

  `include "test_meta.svh"
  logic [7:0] payload[16384];
  logic [7:0] golden[784];
  task automatic dma_load(input string filename, input int count, input logic [31:0] destination);
    logic [31:0] word;
    logic [3:0] keep;
    int waited;
    $readmemh(filename, payload, 0, count - 1);
    wr(MMIO + 'h30c, destination);
    wr(MMIO + 'h310, count);
    wr(MMIO + 'h314, 1);
    wr(MMIO + 'h318, 0);
    wr(MMIO + 'h31c, 0);
    wr(MMIO + 'h320, 0);
    wr(MMIO + 'h334, 0);
    wr(MMIO + 'h300, 1);
    for (int i = 0; i < count; i += 4) begin
      word = 0;
      keep = 0;
      for (int b = 0; b < 4 && i + b < count; b++) begin
        word[b*8+:8] = payload[i+b];
        keep[b] = 1;
      end
      @(negedge clk);
      rx_valid = 1;
      rx_data = word;
      rx_keep = keep;
      rx_last = i + 4 >= count;
      waited = 0;
      do begin
        @(posedge clk);
        waited++;
        if (waited > 100) $fatal(1, "DMA RX timeout");
      end while (!rx_ready);
      @(negedge clk);
      rx_valid = 0;
    end
    wait_unit(MMIO + 'h304);
  endtask
  // FC tails and nonzero activation zero-points exercise GEMM, not CNN.
  // This reference adapter aligns temporary packed operands for general lengths.
  task automatic matrix_dot(input logic [31:0] src, weights, params, raw_dst, input int len, iz);
    logic [31:0] aw, bw, word, multiplier, bias;
    int wsum, byte_offset, count;
    wsum = 0;
    for (int j = 0; j < len; j += 4) begin
      aw = 0;
      bw = 0;
      for (int b = 0; b < 4 && j + b < len; b++) begin
        rd((src + 32'(j + b)) & 32'hfffffffc, word);
        byte_offset = int'((src + 32'(j + b)) & 3);
        aw[b*8+:8] = word[byte_offset*8+:8] ^ 8'h80;
        rd((weights + 32'(j + b)) & 32'hfffffffc, word);
        byte_offset = int'((weights + 32'(j + b)) & 3);
        bw[b*8+:8] = word[byte_offset*8+:8];
        wsum += int'($signed(bw[b*8+:8]));
      end
      wr(SRAM + 'h3000 + 32'(j), aw);
      wr(SRAM + 'h3100 + 32'(j), bw);
    end
    wr(MMIO + 'h110, raw_dst);
    wr(MMIO + 'h114, 1);
    wr(MMIO + 'h118, 1);
    for (int off = 0; off < len; off += 16) begin
      count = len - off > 16 ? 16 : len - off;
      wr(MMIO + 'h108, SRAM + 'h3000 + 32'(off));
      wr(MMIO + 'h10c, SRAM + 'h3100 + 32'(off));
      wr(MMIO + 'h11c, 32'(count));
      wr(MMIO + 'h130, off == 0 ? 8 : 12);
      wr(MMIO + 'h100, 1);
      wait_unit(MMIO + 'h104);
    end
    rd(params, multiplier);
    rd(params + 4, bias);
    wr(SRAM + 'h3c00, multiplier);
    wr(SRAM + 'h3c04, bias);
    wr(SRAM + 'h3c08, 32'((128 - iz) * wsum));
  endtask
  logic [31:0] cnn_raw_location;
  // Exercise separate public interfaces: raw CNN words, then vector U8 post.
  task automatic run_cnn_post(input logic [31:0] src, weights, params, dst, input int width, height,
                              ci, stride, ow, y, iz, oz, legacy_op,
                              input logic [31:0] raw_override = 0);
    cnn_raw_location = raw_override!=0 ? raw_override:checks % 2 ? SRAM + 'h3d00 : npu_addr_pkg::RF_BASE;
    if (legacy_op & 1) begin
      matrix_dot(src, weights, params, cnn_raw_location, width, iz);
    end else begin
      wr(MMIO + 'h608, src);
      wr(MMIO + 'h60c, weights);
      wr(MMIO + 'h610, cnn_raw_location);
      wr(MMIO + 'h614, width);
      wr(MMIO + 'h618, npu_addr_pkg::RF_BASE + npu_addr_pkg::RF_BYTES - 32);
      wr(MMIO + 'h61c, ci);
      wr(MMIO + 'h620, stride);
      wr(MMIO + 'h624, width * height);
      wr(MMIO + 'h62c, iz);
      wr(MMIO + 'h630, 0);
      for (int x = 0; x < ow; x += 8) begin
        int n, rows;
        n = ow - x > 8 ? 8 : ow - x;
        rows = 0;
        for (int r = 0; r < 3; r++)
        if (y * stride + r - 1 >= 0 && y * stride + r - 1 < height) rows |= 1 << r;
        wr(MMIO + 'h628, npu_stream_pkg::encode_task(
           0, y, x, n, rows, x == 0, (x + n - 1) * stride + 1 >= width, x));
        wr(MMIO + 'h600, 1);
      end
      wait_unit(MMIO + 'h604);
    end
    wr(MMIO + 'h208, cnn_raw_location);
    wr(MMIO + 'h218, params);
    wr(MMIO + 'h20c, dst);
    wr(MMIO + 'h210, ow);
    if (legacy_op & 1) begin
      wr(MMIO + 'h218, SRAM + 'h3c00);
      wr(MMIO + 'h234, 32'h409);
      wr(MMIO + 'h240, 32'h40db);  // LD32 r2,[r1+4]: bias
      wr(MMIO + 'h244, 32'h809b);  // LD32 r0,[r1+8]: zero-point correction
      wr(MMIO + 'h248, 32'h00bb);  // LD32 r1,[r1]: M
      wr(MMIO + 'h24c, 32'h225c);  // MADD32 r2,r0,r1,r2
      wr(MMIO + 'h250, 32'h221c);  // MADD32 r0,r0,r1,r2
      wr(MMIO + 'h254, 32'h1881a);
      wr(MMIO + 'h258, 32'h0601);
      wr(MMIO + 'h25c, legacy_op == 3 ? 32'h605 : 32'h805);
      wr(MMIO + 'h260, 32'hff804);
    end else begin
      wr(MMIO + 'h234, 32'h207);
      wr(MMIO + 'h240, 32'h40db);  // LD32 r2,[r1+4]
      wr(MMIO + 'h244, 32'h00bb);  // LD32 r1,[r1]
      wr(MMIO + 'h248, 32'h221c);  // MADD32 r0,r0,r1,r2
      wr(MMIO + 'h24c, 32'h1881a);  // RSHR64 r0,r0,24
      wr(MMIO + 'h250, 32'h0601);  // ADD32 r0,r0,r3
      wr(MMIO + 'h254, (legacy_op == 0 || legacy_op == 3) ? 32'h605 : 32'h805);
      wr(MMIO + 'h258, 32'hff804);  // MIN32 r0,r0,255
    end
    wr(MMIO + 'h214, 32'ha0);
    wr(MMIO + 'h230, oz);
    wr(MMIO + 'h200, 1);
    wait_unit(MMIO + 'h204);
  endtask
  task automatic scalar_case(input int pixel, iz, oz, multiplier, bias, op, expected);
    wr(SRAM + 'h400, (op & 1) ? 1 : 0);
    wr(SRAM + 'h404, !(op & 1) ? 1 : 0);
    wr(SRAM + 'h408, 0);
    wr(SRAM + 'h420, multiplier);
    wr(SRAM + 'h424, bias);
    wr(SRAM + 'h1400, pixel);
    wr(SRAM + 'h1800, 32'hdeadbeef);
    run_cnn_post(SRAM + 'h1400, SRAM + 'h400, SRAM + 'h420, SRAM + 'h1800, 1, 1, 1, 1, 1, 0, iz, oz,
                 op);
    expect_word(SRAM + 'h1800, 32'hdeadbe00 | 32'(expected));
  endtask
  task automatic accumulator_bound(input logic [31:0] weight_word, input int expected);
    for (int i = 0; i < 36; i++) begin
      wr(SRAM + 'h400 + 32'(i * 4), weight_word);
      wr(SRAM + 'h1400 + 32'(i * 4), 32'hffffffff);
    end
    wr(SRAM + 'h500, 256);
    wr(SRAM + 'h504, 0);
    wr(SRAM + 'h1800, 32'hdeadbeef);
    run_cnn_post(SRAM + 'h1400, SRAM + 'h400, SRAM + 'h500, SRAM + 'h1800, 144, 1, 1, 1, 1, 0, 0,
                 128, 1);
    expect_word(SRAM + 'h1800, 32'hdeadbe00 | 32'(expected));
  endtask
  task automatic fc_tail_case(input int len);
    int pixels[144], weights_ref[432], acc, q;
    longint signed scaled, mag, rounded, rem;
    logic [31:0] word, expected;
    for (int j = 0; j < len; j++) pixels[j] = (j * 37 + len * 11) % 256;
    for (int co = 0; co < 3; co++)
      for (int j = 0; j < len; j++) weights_ref[co*len+j] = ((j * 19 + co * 29 + len) % 255) - 127;
    for (int j = 0; j < len; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++) if (j + b < len) word[b*8+:8] = 8'(pixels[j+b]);
      wr(SRAM + 'h1400 + 32'(j), word);
    end
    for (int j = 0; j < 3 * len; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++) if (j + b < 3 * len) word[b*8+:8] = 8'(weights_ref[j+b]);
      wr(SRAM + 'h2000 + 32'(j), word);
    end
    expected = 32'hde000000;
    for (int co = 0; co < 3; co++) begin
      wr(SRAM + 'h2400 + 32'(co * 8), 16384);
      wr(SRAM + 'h2404 + 32'(co * 8), 32'(co * 16777216 - 8388608));
      acc = 0;
      for (int j = 0; j < len; j++) acc += (pixels[j] - 135) * weights_ref[co*len+j];
      scaled = longint'(acc) * 16384 + longint'(co * 16777216 - 8388608);
      mag = scaled < 0 ? -scaled : scaled;
      rounded = mag / 16777216;
      rem = mag % 16777216;
      if (rem > 8388608 || (rem == 8388608 && rounded % 2 != 0)) rounded++;
      q = int'(scaled < 0 ? -rounded : rounded) + 128;
      if (q < 0) q = 0;
      if (q > 255) q = 255;
      expected[co*8+:8] = 8'(q);
    end
    wr(SRAM + 'h1800, 32'hdeadbeef);
    for (int co = 0; co < 3; co++) begin
      run_cnn_post(SRAM + 'h1400, SRAM + 'h2000 + 32'(co * len), SRAM + 'h2400 + 32'(co * 8),
                   SRAM + 'h1800 + 32'(co), len, 1, 1, 1, 1, 0, 135, 128, 1);
    end
    expect_word(SRAM + 'h1800, expected);
  endtask
  task automatic row_case(input int seed, input int placement = 0);
    int w, h, ci, stride, ow, y, acc, q, xx, yy, off;
    int a[300], weights_ref[27];
    logic [31:0] word, got, raw, source_base, weight_base;
    w = 1 + seed % 9;
    h = 1 + (seed * 3) % 7;
    ci = 1 + seed % 3;
    stride = 1 + seed % 2;
    if (placement != 0) begin
      w = 3 + seed % 3;
      h = 3;
    end
    source_base = (placement & 1) ? npu_addr_pkg::RF_BASE : SRAM + 'h1400;
    weight_base = (placement & 2) ? npu_addr_pkg::RF_BASE + 96 : SRAM + 'h2000;
    ow = (w + stride - 1) / stride;
    y = (seed / 2) % ((h + stride - 1) / stride);
    off = 1 + seed % 3;
    for (int j = 0; j < w * h * ci; j++) a[j] = (j * 37 + seed * 17) % 256;
    for (int j = 0; j < ci * 9; j++) weights_ref[j] = ((j * 19 + seed * 11) % 255) - 127;
    for (int j = 0; j < w * h * ci; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++) if (j + b < w * h * ci) word[b*8+:8] = 8'(a[j+b]);
      wr(source_base + 32'(j), word);
    end
    for (int j = 0; j < ci * 9 + off; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++)
      if (j + b >= off && j + b < ci * 9 + off) word[b*8+:8] = 8'(weights_ref[j+b-off]);
      wr(weight_base + 32'(j), word);
    end
    for (int j = 0; j < ow + off + 4; j += 4) wr(SRAM + 'h1800 + 32'(j), 32'ha5a5a5a5);
    wr(SRAM + 'h2400, 16384);
    wr(SRAM + 'h2404, 0);
    run_cnn_post(source_base, weight_base + 32'(off), SRAM + 'h2400, SRAM + 'h1800 + 32'(off), w, h,
                 ci, stride, ow, y, 135, 128, 2,
                 placement != 0 ? npu_addr_pkg::RF_BASE + 160 : 32'b0);
    for (int j = 0; j < ow + off + 4; j++) begin
      if (j % 4 == 0) rd(SRAM + 'h1800 + 32'(j), got);
      q = 165;
      if (j >= off && j < off + ow) begin
        acc = 0;
        for (int c = 0; c < ci; c++)
        for (int ky = 0; ky < 3; ky++)
        for (int kx = 0; kx < 3; kx++) begin
          xx = (j - off) * stride + kx - 1;
          yy = y * stride + ky - 1;
          if (xx >= 0 && xx < w && yy >= 0 && yy < h)
            acc += (a[c*w*h+yy*w+xx] - 135) * weights_ref[c*9+ky*3+kx];
        end
        rd(cnn_raw_location + 32'((j - off) * 4), raw);
        if (raw !== 32'(acc)) $fatal(1, "Raw CNN mismatch seed=%0d lane=%0d", seed, j - off);
        checks++;
        // Q24 M=2^14, ties-to-even division by 1024, then output zero and clamp.
        q = acc < 0 ? -acc : acc;
        if (q % 1024 > 512 || (q % 1024 == 512 && ((q / 1024) % 2))) q = q / 1024 + 1;
        else q = q / 1024;
        if (acc < 0) q = -q;
        q += 128;
        if (q < 0) q = 0;
        if (q > 255) q = 255;
      end
      if (got[(j%4)*8+:8] !== 8'(q))
        $fatal(
            1, "Row mismatch seed=%0d byte=%0d got=%0d expected=%0d", seed, j, got[(j%4)*8+:8], q
        );
      checks++;
    end
  endtask
  task automatic wide_row_case(input int seed);
    int w, h, ci, stride, ow, y, acc, q, xx, yy, off;
    int a[12544], weights_ref[144];
    logic [31:0] word, got, raw;
    w = seed % 4 == 0 ? 16 : seed % 4 == 1 ? 17 : seed % 4 == 2 ? 27 : 28;
    h = seed % 5 == 0 ? 1 : seed % 5 == 1 ? 2 : seed % 5 == 2 ? 3 : seed % 5 == 3 ? 27 : 28;
    ci = 1 << (seed % 5);
    stride = 1 + (seed / 4) % 2;
    ow = (w + stride - 1) / stride;
    if (seed % 3 == 0 && ow > 1) ow--;
    y=seed%3==0 ? 0 : seed%3==1 ? (h+stride-1)/stride-1 : ((h+stride-1)/stride)/2;
    off = 1 + seed % 3;
    for (int j = 0; j < w * h * ci; j++) a[j] = (j * 37 + seed * 17) % 256;
    for (int j = 0; j < ci * 9; j++) weights_ref[j] = ((j * 19 + seed * 11) % 255) - 127;
    for (int j = 0; j < w * h * ci; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++) if (j + b < w * h * ci) word[b*8+:8] = 8'(a[j+b]);
      wr(SRAM + 'h0000 + 32'(j), word);
    end
    for (int j = 0; j < ci * 9 + off; j += 4) begin
      word = 0;
      for (int b = 0; b < 4; b++)
      if (j + b >= off && j + b < ci * 9 + off) word[b*8+:8] = 8'(weights_ref[j+b-off]);
      wr(SRAM + 'h3400 + 32'(j), word);
    end
    for (int j = 0; j < ow + off + 4; j += 4) wr(SRAM + 'h3800 + 32'(j), 32'ha5a5a5a5);
    wr(SRAM + 'h3500, 16384);
    wr(SRAM + 'h3504, 0);
    run_cnn_post(SRAM, SRAM + 'h3400 + 32'(off), SRAM + 'h3500, SRAM + 'h3800 + 32'(off), w, h, ci,
                 stride, ow, y, 135, 128, 2);
    for (int j = 0; j < ow + off + 4; j++) begin
      if (j % 4 == 0) rd(SRAM + 'h3800 + 32'(j), got);
      q = 165;
      if (j >= off && j < off + ow) begin
        acc = 0;
        for (int c = 0; c < ci; c++)
        for (int ky = 0; ky < 3; ky++)
        for (int kx = 0; kx < 3; kx++) begin
          xx = (j - off) * stride + kx - 1;
          yy = y * stride + ky - 1;
          if (xx >= 0 && xx < w && yy >= 0 && yy < h)
            acc += (a[c*w*h+yy*w+xx] - 135) * weights_ref[c*9+ky*3+kx];
        end
        rd(cnn_raw_location + 32'((j - off) * 4), raw);
        if (raw !== 32'(acc)) $fatal(1, "Raw CNN mismatch seed=%0d lane=%0d", seed, j - off);
        checks++;
        // Q24 M=2^14, ties-to-even division by 1024, then output zero and clamp.
        q = acc < 0 ? -acc : acc;
        if (q % 1024 > 512 || (q % 1024 == 512 && ((q / 1024) % 2))) q = q / 1024 + 1;
        else q = q / 1024;
        if (acc < 0) q = -q;
        q += 128;
        if (q < 0) q = 0;
        if (q > 255) q = 255;
      end
      if (got[(j%4)*8+:8] !== 8'(q))
        $fatal(
            1,
            "Wide row mismatch seed=%0d byte=%0d got=%0d expected=%0d",
            seed,
            j,
            got[(j%4)*8+:8],
            q
        );
      checks++;
    end
  endtask
  task automatic edge_tests;
    logic [31:0] ignored;
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    wr(MMIO + 'h600, 1);
    expect_word(MMIO + 'h604, 4);
    wr(MMIO + 'h600, 2);
    transfer(1, MMIO + 'h604, 0, 4'hf, 1, ignored);
    scalar_case(200, 100, 10, 16777216, 0, 0, 110);
    scalar_case(0, 100, 10, 16777216, 0, 0, 10);
    scalar_case(255, 0, 10, 16777216, 0, 0, 255);
    scalar_case(1, 0, 10, 8388608, 0, 0, 10);
    scalar_case(3, 0, 10, 8388608, 0, 0, 12);
    scalar_case(0, 0, 10, 16777216, -8388608, 1, 10);
    scalar_case(0, 0, 10, 16777216, -25165824, 1, 8);
    scalar_case(0, 100, 10, 16777216, 0, 1, 0);
    scalar_case(0, 100, 128, 16777216, 0, 2, 28);  // linear conv keeps negative real result
    scalar_case(0, 100, 128, 16777216, 0, 3,
                128);  // Matrix FC with vector ReLU thresholds at output zero
    scalar_case(200, 100, 128, 16777216, 0, 2, 228);
    scalar_case(200, 100, 128, 16777216, 0, 3, 228);
    // offset*M reaches 2^31: the compensated bias must remain signed INT64.
    scalar_case(255, 0, 0, 16777216, 0, 1, 255);
    scalar_case(0, 255, 128, 16777216, 0, 1, 0);
    accumulator_bound(32'h7f7f7f7f, 199);
    accumulator_bound(32'h80808080, 56);
    // Scalar configuration checks happen on writes; full shape/alias
    // checks now belong to software. Illegal compact counts never enter FIFO.
    transfer(1, MMIO + 'h614, 32'hffffff01, 4'hf, 1, ignored);
    transfer(1, MMIO + 'h618, SRAM + 'h1400, 4'hf, 1, ignored);
    transfer(1, MMIO + 'h610, SRAM + 'h3d01, 4'hf, 1, ignored);
    for (int mode = 1; mode <= 3; mode += 2) transfer(1, MMIO + 'h630, 32'(mode), 4'hf, 1, ignored);
    for (int count = 0; count <= 9; count += 9) begin
      wr(MMIO + 'h628, npu_stream_pkg::encode_task(0, 0, 0, count, 2, 1, 1, 0));
      wr(MMIO + 'h600, 1);
      expect_word(MMIO + 'h604, 4);
      wr(MMIO + 'h600, 2);
    end
    expect_word(MMIO + 'h654, 32'h53443931);
    for (int seed = 0; seed < 36; seed++) row_case(seed);
    for (int placement = 1; placement <= 3; placement++)
      for (int seed = 0; seed < 8; seed++) row_case(seed, placement);
    $display(
        "RF window PASS input/weights/both RF, unaligned weights, raw RF store, mixed gather arbitration");
    for (int seed = 0; seed < 20; seed++) wide_row_case(seed);
    wide_row_case(39);
    wide_row_case(59);
    $display(
        "CNN wide rows PASS: W16/17/27/28, H1/2/3/27/28, Ci1/2/4/8/16, stride1/2, crop/padding/unaligned, cross-bank input");
    for (int len = 1; len <= 16; len++) fc_tail_case(len);
    fc_tail_case(143);
    fc_tail_case(144);
    $display(
        "CNN boundary cases PASS (padding, byte masks, zero-points, ReLU, saturation, signed ties-even, invalid dimensions, overlap)");
  endtask
  longint layer_macs = 0, layer_issues = 0, layer_cycles = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      layer_macs = 0;
      layer_issues = 0;
      layer_cycles = 0;
    end else begin
      if (dut.i_core.cnn_busy) layer_cycles++;
      if (dut.i_core.i_stream.i_engine.tap_valid) begin
        layer_macs += dut.i_core.i_stream.i_engine.tap_count;
        layer_issues++;
      end
    end
  end
  initial begin
    logic [31:0] value, base, ignored;
    int limit, nsamples, cycle_count;
    logic [31:0] macs, issues, bus_count, waits;
    if (dut.i_core.i_stream.i_engine.MACS == 9) expected_terms = '{392, 1568, 1568, 576, 1152, 0};
    edge_tests();
    nsamples = 10;
    limit = $value$plusargs("samples=%d", nsamples);
    if (nsamples < 1 || nsamples > 10) $fatal(1, "samples must be 1..10");
    for (int sample = 0; sample < nsamples; sample ++) begin
      @(negedge clk);
      rst_n = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      dma_load("boot.hex", PROGRAM_BYTES, SRAM);
      dma_load("params.hex", PARAM_BYTES, SRAM + 'h2000);
      dma_load($sformatf("input%0d.hex", sample), 784, SRAM + 'h1400);
      wr(SRAM + 'h1f00, 32'hffffffff);
      wr(SRAM + 'h1f04, 0);
      wr(SRAM + 'h1f08, 0);
      wr(SRAM + 'h1f0c, 1);
      wr(MMIO + 8, 1);
      if (sample == 0) begin
        limit = 0;
        do begin
          rd(MMIO + 'h604, value);
          limit++;
          if (limit > 10000) $fatal(1, "CNN did not start");
        end while (!value[0]);
        transfer(1, MMIO + 'h614, 27, 4'hf, 1, ignored);
        expect_word(MMIO + 'h614, 28);

        wr(MMIO + 'h100, 1);
        rd(MMIO + 'h104, value);
        if (!value[2]) $fatal(1, "Legacy matrix start was not rejected during CNN");
        wr(MMIO + 'h100, 2);  // clear the deliberate legacy matrix-start fault
        $display("CNN writable shadow / shared master exclusion PASS");
      end
      for (int layer = 0; layer < 6; layer++) begin
        limit = 0;
        do begin
          rd(SRAM + 'h1f04, value);
          limit++;
          if (cpu_done && !cpu_pass) $fatal(1, "CPU firmware failure");
          if (limit > 200000) $fatal(1, "Layer timeout sample=%0d layer=%0d", sample, layer);
        end while (value != layer + 1);
        $readmemh($sformatf("gold%0d_%0d.hex", sample, layer), golden, 0, layer_len[layer] - 1);
        base = 32'(layer_base[layer]);
        for (int i = 0; i < layer_len[layer]; i += 4) begin
          rd(base + 32'(i), value);
          for (int b = 0; b < 4 && i + b < layer_len[layer]; b++) begin
            if (value[b*8+:8] !== golden[i+b])
              $fatal(
                  1,
                  "MNIST mismatch sample=%0d layer=%0d element=%0d got=%0d expected=%0d",
                  sample,
                  layer,
                  i + b,
                  value[b*8+:8],
                  golden[i+b]
              );
            checks++;
          end
        end
        if (layer_macs !== expected_macs[layer] || layer_issues !== expected_terms[layer])
          $fatal(
              1,
              "MAC counter mismatch layer=%0d macs=%0d issues=%0d",
              layer,
              layer_macs,
              layer_issues
          );
        $display("ROW PERF sample=%0d layer=%0d kernel_cycles=%0d useful_macs=%0d issued=%0d PASS",
                 sample, layer, layer_cycles, layer_macs, layer_issues);
        layer_macs = 0;
        layer_issues = 0;
        layer_cycles = 0;
        wr(SRAM + 'h1f08, layer + 1);
      end
      limit = 0;
      while (!cpu_done) begin
        @(negedge clk);
        limit++;
        if (limit > 10000) $fatal(1, "CPU argmax timeout");
      end
      if (!cpu_pass) $fatal(1, "CPU failed");
      expect_word(SRAM + 'h1f00, prediction[sample]);
      $display("MNIST sample=%0d prediction=%0d label=%0d PASS", sample, prediction[sample],
               sample);
    end
    // Normal execution: CPU advances without any layer ACK from the host.
    if (nsamples == 10) begin
      @(negedge clk);
      rst_n = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      dma_load("sram7.hex", 16384, SRAM);
      wr(SRAM + 'h1f00, 32'hffffffff);
      wr(SRAM + 'h1f04, 0);
      wr(SRAM + 'h1f08, 0);
      wr(SRAM + 'h1f0c, 0);
      wr(MMIO + 8, 1);
      limit = 0;
      while (!cpu_done) begin
        repeat (100) @(negedge clk);
        limit++;
        if (limit > 10000) $fatal(1, "Normal mode timeout");
      end
      if (!cpu_pass) $fatal(1, "Normal mode CPU failed");
      expect_word(SRAM + 'h1f00, 7);
      expect_word(SRAM + 'h1f04, 6);
      $readmemh("gold7_5.hex", golden, 0, 9);
      for (int i = 0; i < 10; i += 4) begin
        rd(SRAM + 'h1400 + 32'(i), value);
        for (int b = 0; b < 4 && i + b < 10; b++) begin
          if (value[b*8+:8] !== golden[i+b]) $fatal(1, "Normal mode logit mismatch");
          checks++;
        end
      end
      $display("MNIST normal mode without host layer ACK PASS prediction=7");
    end
    $display("MNIST PASS samples=%0d exact_activation_checks=%0d transactions=%0d", nsamples,
             checks, transactions);
    $finish;
  end
  initial begin
    #2000000000;
    $fatal(1, "Global timeout");
  end
endmodule
