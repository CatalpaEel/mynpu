`timescale 1ns / 1ps
// Direct arithmetic contracts: no descriptors, bus models, programs or address generation.
module tb_pure_compute;
  logic clk_i = 0, rst_ni = 0, flush_i = 0, valid_i = 0, ready_i = 0, multiply_i = 0, emit_i = 0;
  always #10 clk_i = ~clk_i;
  logic signed [15:0] a_i = 0, b_i = 0;
  logic [31:0] addend_i = 0;
  wire ready_o, valid_o;
  wire [31:0] data_o;
  npu_matmul matrix (
    .extra_valid_i(3'b0),
    .extra_a_i    (48'b0),
    .extra_b_i    (48'b0),
    .*
  );
  logic [4:0] op = 0;
  logic [31:0] a = 0, b = 0, c = 0;
  logic carry_in = 0, carry_out;
  logic simd = 0;
  wire [31:0] value;
  npu_vector vector (
    .op_i   (op),
    .simd_i (simd),
    .a_i    (a),
    .b_i    (b),
    .c_i    (c),
    .carry_i(carry_in),
    .carry_o(carry_out),
    .data_o (value)
  );
  function automatic logic [31:0] reference(input int operation, input logic [31:0] x, y, z,
                                            input bit ci);
    longint signed wide, quotient, remainder, divisor;
    longint unsigned unsigned_product;
    logic [31:0] result;
    int amount;
    wide = longint'($signed(x)) * longint'($signed(y));
    unsigned_product = 64'(x) * 64'(y);
    case (operation)
      0: return x[31] ? 0 : x;
      1, 16: return x + y;
      2: return x;
      3: return x - y;
      4: return $signed(x) < $signed(y) ? x : y;
      5: return $signed(x) > $signed(y) ? x : y;
      6: return x & y;
      7: return x | y;
      8: return x ^ y;
      9: return x << y[4:0];
      10: return x >> y[4:0];
      11: return $signed(x) >>> y[4:0];
      12: return 32'(x == y);
      13: return -x;
      14: return x[31] ? -x : x;
      15: return ~x;
      17: return x + y + 32'(ci);
      18: return 32'(x < y);
      19: return unsigned_product[63:32];
      20: return 32'(wide >>> 32);
      23: return x + (y[31] ? 32'hffffffff : 0) + 32'(ci);
      24: return 32'(wide);
      29: return z;
      21, 22, 26: begin
        amount = operation == 26 ? int'(y[4:0]) : int'(z[5:0]);
        if (amount > 32) return 0;
        wide = operation == 26 ? longint'($signed(x)) : $signed({y, x});
        if (amount == 0) return x;
        divisor = 64'd1 << amount;
        // Independent division/remainder oracle, including negative halfway cases.
        quotient = wide / divisor;
        remainder = wide % divisor;
        if (operation == 21) begin
          if (remainder < 0) quotient--;
        end else if (remainder > divisor / 2 || remainder == divisor / 2 && quotient[0]) quotient++;
        else if (remainder < -divisor / 2 || remainder == -divisor / 2 && quotient[0]) quotient--;
        return 32'(quotient);
      end
      default: return 0;
    endcase
  endfunction
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
  logic [31:0] ref_acc = 0;
  bit ref_valid = 0;
  int checks = 0, accepted = 0, stalls = 0, vector_checks = 0;
  always @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      ref_acc = 0;
      ref_valid = 0;
    end else begin
      if (valid_o && !ready_i) stalls++;
      if (ready_o) begin
        ref_valid = valid_i && emit_i;
        if (valid_i) begin
          ref_acc = ref_acc + (multiply_i ? 32'(longint'(a_i) * longint'(b_i)) : addend_i);
          accepted++;
        end
      end
    end
    #1;
    if (data_o !== ref_acc || valid_o !== ref_valid)
      $fatal(1, "Pure matrix mismatch got=%h expected=%h", data_o, ref_acc);
    checks++;
  end
  initial begin
    logic [31:0] expected;
    logic [32:0] carry_reference;
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int n = 0; n < 12000; n++) begin
      @(negedge clk_i);
      flush_i = n % 139 == 0;
      valid_i = $urandom_range(0, 3) != 0;
      ready_i = n % 32 >= 8 && $urandom_range(0, 3) != 0;
      multiply_i = n % 5 != 0;
      emit_i = n % 4 != 0;
      a_i = n < 16 ? 16'sh8000 : 16'($urandom);
      b_i = n < 16 ? 16'sh8000 : 16'($urandom);
      addend_i = $urandom;
      op = 5'(n % 32);
      simd = 1'((n / 32) % 2);
      a = $urandom;
      b = $urandom;
      c = $urandom;
      carry_in = 1'(n % 2);
      if (n < 6000 && n % 4 == 0) a = 32'h80000000;
      if (n < 6000 && n % 4 == 1) a = 32'h7fffffff;
      if (n < 6000 && n % 4 == 2) b = 32'hffffffff;
      c = 32'(n % 33);
      expected = simd ? reference8(int'(op), a, b, c) : reference(int'(op), a, b, c, carry_in);
      carry_reference={1'b0,a}+{1'b0,(op==23 ? {32{b[31]}}:b)}+33'((op==17 || op==23) && carry_in);
      #1;
      if(value!==expected || (!simd && (op==16 || op==17 || op==23) && carry_out!==carry_reference[32]) || (simd && carry_out!==0))
        $fatal(
            1,
            "ALU mismatch n=%0d simd=%0d op=%0d a=%h b=%h c=%h got=%h want=%h",
            n,
            simd,
            op,
            a,
            b,
            c,
            value,
            expected
        );
      vector_checks++;
    end
    @(negedge clk_i);
    valid_i = 0;
    ready_i = 1;
    flush_i = 0;
    repeat (3) @(negedge clk_i);
    if (accepted < 500 || stalls < 100) $fatal(1, "Insufficient matrix coverage");
    $display(
        "PURE COMPUTE PASS matrix_checks=%0d accepted=%0d stalls=%0d vector_checks=%0d INT32/SIMD8/mul-high/word-pair-shift/carry/backpressure/flush",
        checks, accepted, stalls, vector_checks);
    $finish;
  end
endmodule
