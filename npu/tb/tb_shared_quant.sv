`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_shared_quant;
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
  task automatic bus(input bit we, input logic [31:0] a, d, output logic [31:0] result,
                     input bit expected_error = 0);
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
    if (!hv || he != expected_error) $fatal(1, "host response/error %h", a);
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

  function automatic logic [31:0] quant_ref(input logic [31:0] raw, mul, bias, offset, zero, lo, hi,
                                            input int amount);
    logic [31:0] corrected, translated;
    longint signed wide, q, r, divisor;
    corrected = raw + offset;
    wide = longint'($signed(corrected)) * longint'($signed(mul)) + longint'($signed(bias));
    divisor = 64'sd1 << amount;
    q = wide / divisor;
    r = wide % divisor;
    if (amount != 0) begin
      if (r > divisor / 2 || r == divisor / 2 && q % 2 != 0) q++;
      if (r < -divisor / 2 || r == -divisor / 2 && q % 2 != 0) q--;
    end
    translated = 32'(q) + zero;
    return $signed(
        translated
    ) < $signed(
        lo
    ) ? lo : $signed(
        translated
    ) > $signed(
        hi
    ) ? hi : translated;
  endfunction
  task automatic settings(input int id, mode, input logic [31:0] mul, bias, offset, zero, lo, hi,
                          dst, input int amount);
    logic [31:0] base;
    base = 'h40000700 + 64 * id;
    wr(base + 4, mul);
    wr(base + 8, bias);
    wr(base + 12, 32'(amount));
    wr(base + 16, zero);
    wr(base + 20, lo);
    wr(base + 24, hi);
    wr(base + 28, offset);
    wr(base + 32, dst);
    wr(base, 32'(mode));
  endtask
  task automatic bad_wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    bus(1, a, d, ignored, 1);
    checks++;
  endtask
  // Translate the regression oracle's old layout tuple into explicit MMIO fields.
  task automatic matrix_config(input logic [31:0] f);
    wr('h4000013c, {31'b0, f[4]});
    wr('h40000140, f[3] ? (f[4] ? 2 : 1) : 4);
    wr('h40000130, f <= 31 ? (f & 7) : f);
  endtask
  initial begin
    logic [31:0] got, mul, bias, offset, zero, lo, hi, cd, md, expected_c, expected_m;
    int input_value, weight, amount, mode;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    rd('h40000780, got);
    if (got !== 'h51543031) $fatal(1, "quant capability");
    for (int n = 0; n < 160; n++) begin
      mode = n % 3;
      mode = mode == 2 ? 3 : mode;
      amount = n % 33;
      input_value = n % 127 + 1;
      weight = n % 31 - 15;
      mul = $urandom;
      bias = $urandom;
      offset = $urandom;
      zero = $urandom;
      lo = n % 2 ? 'hffffff80 : 0;
      hi = n % 2 ? 127 : 255;
      if (n < 40) begin
        mul = 3;
        bias = 32'(n - 20);
        offset = 0;
        zero = 0;
      end
      cd = n % 2 ? 'h800040a1 : 'h80001701;
      md = n % 2 ? 'h800040b2 : 'h80001802;
      if (mode != 3) begin
        cd = {cd[31:2], 2'b0};
        md = {md[31:2], 2'b0};
      end
      settings(0, mode, mul, bias, offset, zero, lo, hi, cd, amount);
      settings(1, mode, ~mul, ~bias, offset ^ 32'h5555, zero + 7, lo, hi, md, (amount + 7) % 33);
      wr(INPUT_A, 32'(input_value));
      wr({cd[31:2], 2'b0}, 'ha5a5a5a5);
      wr({md[31:2], 2'b0}, 'ha5a5a5a5);
      configure(0, INPUT_A, 'h80001900, weight);
      configure(1, INPUT_A, 'h80001904, weight);
      start(0);
      start(1);
      wait_done(0);
      wait_done(1);
      expected_c = quant_ref(32'(input_value * weight), mul, bias, offset, zero, lo, hi, amount);
      expected_m = quant_ref(
          32'(input_value * weight),
          ~mul,
          ~bias,
          offset ^ 32'h5555,
          zero + 7,
          lo,
          hi,
          (amount + 7) % 33
      );
      if (mode == 0) begin
        rd('h80001900, got);
        if (got !== 32'(input_value * weight)) $fatal(1, "raw CNN %h", got);
        rd('h80001904, got);
        if (got !== 32'(input_value * weight)) $fatal(1, "raw Matrix %h", got);
      end else begin
        if (mode == 3) begin
          expected_c = 'ha5a5a5a5;
          expected_m = 'ha5a5a5a5;
          expected_c[8*int'(cd[1:0])+:8] =
              8'(quant_ref(32'(input_value * weight), mul, bias, offset, zero, lo, hi, amount));
          expected_m[8*int'(md[1:0])+:8] = 8'(quant_ref(
              32'(input_value * weight),
              ~mul,
              ~bias,
              offset ^ 32'h5555,
              zero + 7,
              lo,
              hi,
              (amount + 7) % 33
          ));
        end
        rd({cd[31:2], 2'b0}, got);
        if (got !== expected_c)
          $fatal(1, "CNN quant n=%0d mode=%0d got=%h expected=%h", n, mode, got, expected_c);
        rd({md[31:2], 2'b0}, got);
        if (got !== expected_m)
          $fatal(1, "Matrix quant n=%0d mode=%0d got=%h expected=%h", n, mode, got, expected_m);
      end
      checks += 2;
    end
    // Two-channel CNN: partial RF must stay INT32 until final input channel.
    settings(0, 3, 2, 0, 0, 0, 0, 255, 'h80001803, 0);
    wr(INPUT_A, 'h00000606);
    configure(0, INPUT_A, 'h80001900, 2);
    wr(WEIGHTS + 12, 'h00000300);
    wr(WEIGHTS + 16, 0);
    wr('h4000061c, 2);
    wr('h40000624, 1);
    wr('h80001800, 'ha5a5a5a5);
    start(0);
    wait_done(0);
    rd('h80001800, got);
    if (got !== 'h3ca5a5a5) $fatal(1, "CNN partial quantized early %h", got);
    checks++;
    // Matrix accumulation reads raw D, quantized result has a distinct destination.
    settings(1, 3, 2, 0, 0, 0, 0, 255, 'h80001801, 0);
    wr(INPUT_A, 6);
    configure(1, INPUT_A, 'h80001904, 3);
    wr('h80001904, 7);
    matrix_config(4);
    start(1);
    wait_done(1);
    rd('h80001800, got);
    if (got !== 'h3ca532a5) $fatal(1, "Matrix raw accumulation/quant destination %h", got);
    checks++;
    // Software may update quant settings while Matrix waits for input.
    settings(1, 3, 2, 0, 0, 0, 0, 255, 'h80001800, 0);
    configure(1, CHANNEL, 'h80001904, 3);
    matrix_config(0);
    start(1);
    wr('h40000744, 99);
    rd('h40000744, got);
    if (got !== 99) $fatal(1, "runtime quant setting write rejected");
    wr('h40000744, 2);  // Restore before producing the result that uses it.
    wr(CHANNEL, 6);
    wait_done(1);
    rd('h80001800, got);
    if (got[7:0] !== 36) $fatal(1, "locked quant settings not used");
    bad_wr('h4000074c, 33);
    bad_wr('h40000740, 2);
    wr('h40000740, 0);
    wr('h40000760, CHANNEL);
    bad_wr('h40000740, 3);
    // Maximum tile: sixteen positions, three input channels, raw partials in RF.
    for (int packed_mode = 0; packed_mode < 2; packed_mode++)
    for (int rf_target = 0; rf_target < 2; rf_target++) begin
      logic [31:0] target, word;
      target=rf_target ? (packed_mode ? 'h80004081:'h80004080) : (packed_mode ? 'h80001a01:'h80001a00);
      settings(0, packed_mode ? 3 : 1, 1, 0, 0, 0, 0, 255, target, 0);
      configure(0, INPUT_A, 'h80001900, 1);
      for (int w = 0; w < 12; w++) begin
        word = 0;
        for (int b = 0; b < 4; b++) word[8*b+:8] = 8'(((w * 4 + b) / 16) * 20 + (w * 4 + b) % 16);
        wr(INPUT_A + 32'(w * 4), word);
      end
      for (int w = 0; w < 7; w++) begin
        word = 0;
        for (int b = 0; b < 4; b++) if ((w * 4 + b) % 9 == 4) word[8*b+:8] = 1;
        wr(WEIGHTS + 32'(w * 4), word);
      end
      wr('h4000061c, 3);
      wr('h40000614, 16);
      wr('h40000624, 16);
      wr('h40000628, npu_stream_pkg::encode_task(0, 0, 16, 2, 1, 1, 0));
      start(0);
      wait_done(0);
      for (int p = 0; p < 16; p++) begin
        if (packed_mode) begin
          rd((target + 32'(p)) & 32'hfffffffc, got);
          got = (got >> (((target + 32'(p)) & 3) * 8)) & 255;
        end else rd(target + 32'(p * 4), got);
        if (got !== 32'(60 + 3 * p))
          $fatal(
              1,
              "CNN count16 final quant mode/rf/pos=%0d/%0d/%0d got=%h",
              packed_mode,
              rf_target,
              p,
              got
          );
        checks++;
      end
    end
    // Quant32 may stream. Fill its FIFO to exercise stable output backpressure.
    settings(0, 1, 1, 0, 0, 0, 0, 255, CHANNEL, 0);
    for (int w = 0; w < 13; w++) wr(INPUT_A + 4 * w, 'h06060606);
    configure(0, INPUT_A, 'h80001900, 3);
    for (int task_id = 0; task_id < 3; task_id++) begin
      wr('h40000628, 32'(task_id * 16) << 9 | 15 << 0 | 2 << 4 | (task_id == 0 ? 1 << 7 : 0));
      start(0);
    end
    repeat (300) @(negedge clk);
    if (!dut.i_core.i_quant.valid_o[0] || dut.i_core.i_quant.ready_i[0])
      $fatal(1, "quant FIFO did not backpressure");
    repeat (12) begin
      @(negedge clk);
      if (!dut.i_core.i_quant.valid_o[0] || dut.i_core.i_quant.data_o[0] !== 18)
        $fatal(1, "stalled quant result changed");
    end
    for (int w = 0; w < 48; w++) begin
      rd(CHANNEL, got);
      if (got !== 18) $fatal(1, "quant FIFO order/data %h", got);
      checks++;
    end
    wait_done(0);
    $display(
        "SHARED QUANT PASS checks=%0d raw/quant32/quant8/concurrent/CNN-partial/Matrix-accumulate/signed-round/wrap/tail/RF/SRAM",
        checks);
    $finish;
  end
endmodule
