`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_cnn_stream;
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

  task automatic convolution(input int sample);
    int h, w, ci, step, oh, ow, y, x, count, co, zero, expected, rows, px, py, value;
    int input_bytes, weight_bytes;
    logic [31:0] a, b, d, got, word;
    logic [7:0] pixels[4096];
    int weights[288];
    w = sample % 17 + 1;
    h = (sample * 3) % 9 + 1;
    ci = sample % 4 + 1;
    step = sample % 2 + 1;
    if (sample >= 160) begin
      ci = sample[0] ? 16 : 8;
      w = sample % 5 + 1;
      h = sample % 3 + 1;
    end
    oh = (h + step - 1) / step;
    ow = (w + step - 1) / step;
    count = ow < 8 ? ow : 8;
    y = sample % 2 ? oh - 1 : 0;
    x = sample % 3 ? ow - count : 0;
    co = sample % 2;
    zero = (sample * 37) % 256;
    input_bytes = ci * h * w;
    weight_bytes = 2 * ci * 9;
    a = input_bytes <= 128 && sample[1] ? 'h80004000 : 'h80001000;
    b = sample[2] && weight_bytes <= 96 ? 'h80004080 : 'h80002000;
    d = 'h80001800;
    for (int j = 0; j < input_bytes; j++) pixels[j] = 8'($urandom);
    for (int j = 0; j < weight_bytes; j++) weights[j] = int'($urandom_range(0, 255)) - 128;
    for (int j = 0; j < (input_bytes + 3) / 4; j++) begin
      word = 0;
      for (int lane = 0; lane < 4; lane++)
      if (4 * j + lane < input_bytes) word[8*lane+:8] = pixels[4*j+lane];
      wr(a + 4 * j, word);
    end
    for (int j = 0; j < (weight_bytes + 3) / 4; j++) begin
      word = 0;
      for (int lane = 0; lane < 4; lane++)
      if (4 * j + lane < weight_bytes) word[8*lane+:8] = 8'(weights[4*j+lane]);
      wr(b + 4 * j, word);
    end
    for (int j = 0; j < count + 1; j++) wr(d + 4 * j, 'hdeadbeef);
    rows = 0;
    for (int r = 0; r < 3; r++) if (y * step + r - 1 >= 0 && y * step + r - 1 < h) rows |= 1 << r;
    wr('h40000608, a);
    wr('h4000060c, b);
    wr('h40000610, d);
    wr('h40000614, 32'(w));
    wr('h40000618, 'h800040e0);
    wr('h4000061c, 32'(ci));
    wr('h40000620, 32'(step));
    wr('h40000624, 32'(h * w));
    wr('h4000062c, 32'(zero));
    wr('h40000630, 0);
    wr('h40000628,
       32'(co)|32'(y)<<4|32'(x)<<9|32'(count)<<14|32'(rows)<<18|32'(x==0)<<21|32'((x+count-1)*step+1>=w)<<22);
    start(0);
    wait_done(0);
    for (int pos = 0; pos < count; pos++) begin
      expected = 0;
      for (int c = 0; c < ci; c++)
      for (int r = 0; r < 3; r++)
      for (int col = 0; col < 3; col++) begin
        py = y * step + r - 1;
        px = (x + pos) * step + col - 1;
        if (py >= 0 && py < h && px >= 0 && px < w)
          expected += (int'(pixels[(c*h+py)*w+px]) - zero) * weights[(co*ci+c)*9+r*3+col];
      end
      rd(d + 4 * pos, got);
      if (got !== 32'(expected))
        $fatal(
            1,
            "CNN stream sample=%0d H/W/C=%0d/%0d/%0d step=%0d pos=%0d got=%h expected=%h",
            sample,
            h,
            w,
            ci,
            step,
            pos,
            got,
            expected
        );
      checks++;
    end
    rd(d + 4 * count, got);
    if (got !== 'hdeadbeef) $fatal(1, "CNN tail write");
    checks++;
  endtask
  initial begin
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    for (int sample = 0; sample < 192; sample ++) convolution(sample);
    // Packed FIFO input, circular window across four word boundaries.
    for (int w = 0; w < 4; w++) begin
      logic [31:0] word;
      word = 0;
      for (int b = 0; b < 4; b++) word[8*b+:8] = 8'(4 * w + b);
      wr(CHANNEL, word);
    end
    configure(0, CHANNEL, 'h80001800, 1);
    wr('h40000614, 15);
    wr('h40000620, 2);
    wr('h40000624, 15);
    wr('h40000628, 8 << 14 | 2 << 18 | 1 << 21 | 1 << 22);
    start(0);
    wait_done(0);
    for (int i = 0; i < 8; i++) begin
      logic [31:0] got;
      rd('h80001800 + 4 * i, got);
      if (got !== 32'(i * 2)) $fatal(1, "CNN FIFO/stride2 element=%0d got=%h", i, got);
      checks++;
    end
    $display(
        "CNN STREAM PASS cases=193 checks=%0d stride1/2/borders/unaligned-rows/1..16-channels/RF/SRAM",
        checks);
    $finish;
  end
endmodule
