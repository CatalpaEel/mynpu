`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_vector_simd;
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
  // Independent byte oracle uses integer arithmetic, not segmented RTL logic.
  function automatic logic [31:0] reference8(input int operation, input logic [31:0] x, y, z);
    logic [31:0] result;
    int sx, sy, ux, uy, v, amount, divisor, q, r;
    result = 0;
    for (int lane = 0; lane < 4; lane++) begin
      ux = int'(x[8*lane+:8]);
      uy = int'(y[8*lane+:8]);
      sx = ux >= 128 ? ux - 256 : ux;
      sy = uy >= 128 ? uy - 256 : uy;
      amount = uy % 8;
      v = 0;
      case (operation)
        0: v = sx < 0 ? 0 : sx;
        1: v = sx + sy;
        2: v = ux;
        3: v = sx - sy;
        4: v = sx < sy ? sx : sy;
        5: v = sx > sy ? sx : sy;
        6: v = ux & uy;
        7: v = ux | uy;
        8: v = ux ^ uy;
        9: v = ux << amount;
        10: v = ux >> amount;
        11: v = sx >>> amount;
        12: v = int'(ux == uy);
        13: v = -sx;
        14: v = sx < 0 ? -sx : sx;
        15: v = ~ux;
        18: v = int'(ux < uy);
        19: v = (ux * uy) >> 8;
        20: v = (sx * sy) >>> 8;
        24: v = sx * sy;
        26: begin
          divisor = 1 << amount;
          q = sx / divisor;
          r = sx % divisor;
          if (amount != 0) begin
            if (r > divisor / 2 || r == divisor / 2 && q % 2 != 0) q++;
            if (r < -divisor / 2 || r == -divisor / 2 && q % 2 != 0) q--;
          end
          v = q;
        end
        29: v = int'(z[8*lane+:8]);
        default: v = 0;
      endcase
      result[8*lane+:8] = 8'(v);
    end
    return result;
  endfunction

  function automatic bit supported(input int op);
    return op <= 15 || op >= 18 && op <= 20 || op == 24 || op == 26;
  endfunction
  task automatic configure_simd(input logic [31:0] a, b, d, input int len, mode);
    wr('h40000208, a);
    wr('h40000218, b);
    wr('h4000020c, d);
    wr('h40000210, 32'(len));
    wr('h40000214, 32'(mode));
    wr('h40000230, 'hfffffffd);
  endtask
  task automatic direct_case(input int op, len, kind, inplace, input bit scalar_input);
    logic [31:0] a, b, d, x, y, got;
    logic [31:0] ax[8], by[8], expected[8];
    int words;
    words = (len + 3) / 4;
    a = kind[0] ? 'h80004000 : 'h80001000;
    b = kind[1] ? 'h80004040 : 'h80002000;
    d = inplace == 1 ? a : inplace == 2 ? b : 'h80001800;
    for (int w = 0; w < words; w++) begin
      x = $urandom;
      y = $urandom;
      if (w == 0) begin
        x = 'hff807f00;
        y = 'h0107ff80;
      end
      ax[w] = x;
      by[w] = y;
      wr(a + 4 * w, x);
      wr(b + 4 * w, y);
      if (inplace == 0) wr(d + 4 * w, 'ha5a5a5a5);
      expected[w] = inplace == 1 ? x : inplace == 2 ? y : 'ha5a5a5a5;
      got = reference8(op, x, scalar_input ? 'hfdfdfdfd : y, 0);
      for (int lane = 0; lane < 4; lane++)
      if (4 * w + lane < len) expected[w][8*lane+:8] = got[8*lane+:8];
    end
    configure_simd(a, b, d, len, 'h40 | op | (scalar_input ? 'h80 : 0));
    start(2);
    wait_done(2);
    for (int w = 0; w < words; w++) begin
      rd(d + 4 * w, got);
      if (got !== expected[w])
        $fatal(
            1,
            "SIMD op=%0d len=%0d kind=%0d inplace=%0d scalar=%0d word=%0d got=%h want=%h",
            op,
            len,
            kind,
            inplace,
            scalar_input,
            w,
            got,
            expected[w]
        );
      checks++;
    end
  endtask
  function automatic logic [31:0] ins(input int op, rd, ra, rb, input bit immediate, input int imm);
    return 32'(op | rd << 5 | ra << 7 | rb << 9 | int'(immediate) << 11 | imm << 12);
  endfunction
  task automatic program_case(input int len);
    logic [31:0] x, expected[8], got;
    for (int w = 0; w < (len + 3) / 4; w++) begin
      x = $urandom;
      wr('h80001000 + 4 * w, x);
      wr('h80001800 + 4 * w, 'ha5a5a5a5);
      expected[w] = reference8(1, x, 'hfdfdfdfd, 0);
      expected[w] = reference8(8, expected[w], 'h55555555, 0);
      expected[w] = reference8(24, expected[w], 'h07070707, 0);
      for (int lane = 0; lane < 4; lane++) if (4 * w + lane >= len) expected[w][8*lane+:8] = 'ha5;
    end
    wr('h40000234, 3);
    wr('h40000240, ins(1, 0, 0, 0, 1, -3));
    wr('h40000244, ins(8, 0, 0, 0, 1, 'h55));
    wr('h40000248, ins(24, 0, 0, 0, 1, 7));
    configure_simd('h80001000, 0, 'h80001800, len, 'h60);
    start(2);
    wait_done(2);
    for (int w = 0; w < (len + 3) / 4; w++) begin
      rd('h80001800 + 4 * w, got);
      if (got !== expected[w])
        $fatal(1, "SIMD program len=%0d word=%0d got=%h want=%h", len, w, got, expected[w]);
      checks++;
    end
  endtask
  task automatic reject_job(input logic [31:0] a, d, input int mode);
    logic [31:0] before_count, after_count;
    configure_simd(a, 0, d, 5, mode);
    rd('h4000022c, before_count);
    start(2);
    rd('h4000022c, after_count);
    if (after_count !== before_count)
      $fatal(1, "Invalid SIMD descriptor accepted a=%h d=%h mode=%h", a, d, mode);
    checks++;
  endtask
  initial begin
    logic [31:0] got;
    int lens[9] = '{1, 2, 3, 4, 5, 7, 16, 17, 31};
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    rd('h40000068, got);
    if (got !== 'h00030408) $fatal(1, "SIMD capability %h", got);
    for (int op = 0; op < 32; op++)
    if (supported(op))
      for (int k = 0; k < 9; k++)
      for (int kind = 0; kind < 4; kind++)
      for (int inplace = 0; inplace < 3; inplace++)
      for (int scalar_input = 0; scalar_input < 2; scalar_input++)
      direct_case(op, lens[k], kind, inplace, 1'(scalar_input));
    for (int k = 0; k < 9; k++) program_case(lens[k]);
    // SCALAR broadcasts a byte to all lanes; LD32 remains a full packed-word load.
    wr('h80002000, 'h817f01ff);
    wr('h80001000, 'h01020304);
    wr('h40000234, 'h104);  // prefix LD32 into r2, loop ADD then XOR with scalar r3
    wr('h40000240, ins(27, 2, 1, 0, 1, 0));
    wr('h40000244, ins(1, 0, 0, 2, 0, 0));
    wr('h40000248, ins(29, 3, 0, 0, 0, 0));
    wr('h4000024c, ins(8, 0, 0, 3, 0, 0));
    configure_simd('h80001000, 'h80002000, 'h80001800, 4, 'h60);
    start(2);
    wait_done(2);
    rd('h80001800, got);
    if (got !== reference8(8, reference8(1, 'h01020304, 'h817f01ff, 0), 'hfdfdfdfd, 0))
      $fatal(1, "SIMD prefix/scalar %h", got);
    checks++;
    // Packed words cross the generic FIFO, including a partial final word.
    wr('h80001000, 'h7f80ff00);
    wr('h80001004, 'hccccccfe);
    wr('h80001800, 0);
    wr('h80001804, 'ha5a5a5a5);
    // Host writes packed words to the same channel used by compute producers.
    wr(CHANNEL, 'h7c7dfcfd);
    wr(CHANNEL + 4, 'h000000fb);
    configure_simd(CHANNEL, 0, 'h80001800, 5, 'hc8);  // XOR scalar -3
    start(2);
    for (int k = 0; k < 1000; k++) begin
      rd('h40000204, got);
      if (got[2]) $fatal(1, "SIMD FIFO fault");
      if (!got[0] && got[1]) break;
    end
    if (got[0]) $fatal(1, "SIMD FIFO timeout");
    rd('h80001800, got);
    if (got !== reference8(8, reference8(1, 'h7f80ff00, 'hfdfdfdfd, 0), 'hfdfdfdfd, 0))
      $fatal(1, "SIMD FIFO word %h", got);
    rd('h80001804, got);
    if (got !== 'ha5a5a506) $fatal(1, "SIMD FIFO tail %h", got);
    checks += 2;
    wr('h40000234, 1);
    reject_job('h80001000, 'h80001800, 'he0);
    reject_job('h12340000, 'h80001800, 'h60);
    reject_job('h80001000, 'h80001004, 'h60);  // partially overlapping ranges
    reject_job('h80001002, 'h80001800, 'h60);
    for (int op = 16; op <= 23; op++)
    if (op == 16 || op == 17 || op >= 21) begin
      wr('h40000240, ins(op, 0, 0, 0, 0, 0));
      configure_simd('h80001000, 0, 'h80001800, 4, 'h60);
      start(2);
      for (int k = 0; k < 100; k++) begin
        rd('h40000204, got);
        if (got[2] && !got[0]) break;
      end
      if (!got[2] || got[0]) $fatal(1, "Unsupported SIMD op=%0d did not fault", op);
      checks++;
    end
    $display("VECTOR SIMD PASS checks=%0d direct/program/SRAM/RF/inplace/scalar/tail/fault",
             checks);
    $finish;
  end
endmodule
