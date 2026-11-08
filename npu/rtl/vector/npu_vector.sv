// One configurable INT32 / four-lane INT8 ALU. Byte carry boundaries are
// disabled in SIMD mode. Add/sub/neg/abs, comparisons, shifts and partial
// multipliers are shared; there is no separate light ALU.
module npu_vector #(
  parameter bit PIPELINED_MUL = 0
) (
  input logic mul_simd_i,
  input logic [31:0] mul_a_i,
  mul_b_i,
  input logic [4:0] op_i,
  input logic simd_i,
  input logic [31:0] a_i,
  b_i,
  c_i,
  input logic carry_i,
  output logic carry_o,
  output logic [31:0] data_o
);
  logic [31:0] multiply_a, multiply_b;
  logic multiply_simd;
  assign multiply_simd = PIPELINED_MUL ? mul_simd_i : simd_i;
  assign multiply_a = PIPELINED_MUL ? mul_a_i : a_i;
  assign multiply_b = PIPELINED_MUL ? mul_b_i : b_i;
  logic [31:0] p00, p01, p10, p11, middle, product_low, product_high;
  logic [31:0] lhs, rhs, sum, high_base, correction_a, correction_b, signed_high;
  logic subtract;
  logic [4:0] carries;
  logic [3:0] byte_equal, byte_less, byte_signed_less;
  logic unsigned_less, signed_less;
  logic [31:0] shift_stage[6];
  logic [31:0] pair_shifted, pair_mask;
  logic [5:0] pair_amount;
  // Reuse the existing four 16x16 partial multipliers as four 8x8 lanes.
  assign p00 = (multiply_simd ? {8'b0, multiply_a[7:0]} : multiply_a[15:0]) * (multiply_simd ? {8'b0, multiply_b[7:0]} : multiply_b[15:0]);
  assign p01 = (multiply_simd ? {8'b0, multiply_a[15:8]} : multiply_a[15:0]) * (multiply_simd ? {8'b0, multiply_b[15:8]} : multiply_b[31:16]);
  assign p10=(multiply_simd ? {8'b0,multiply_a[23:16]}:multiply_a[31:16]) * (multiply_simd ? {8'b0,multiply_b[23:16]}:multiply_b[15:0]);
  assign p11=(multiply_simd ? {8'b0,multiply_a[31:24]}:multiply_a[31:16]) * (multiply_simd ? {8'b0,multiply_b[31:24]}:multiply_b[31:16]);
  assign middle = {16'b0, p00[31:16]} + {16'b0, p01[15:0]} + {16'b0, p10[15:0]};
  assign product_low=multiply_simd ? {p11[7:0],p10[7:0],p01[7:0],p00[7:0]} : {middle[15:0],p00[15:0]};
  assign product_high=multiply_simd ? {p11[15:8],p10[15:8],p01[15:8],p00[15:8]} : p11+{16'b0,p01[31:16]}+{16'b0,p10[31:16]}+{16'b0,middle[31:16]};
  function automatic logic [31:0] segmented_sub(input logic [31:0] x, y, input logic segmented);
    logic carry;
    logic [8:0] value;
    logic [31:0] result;
    carry = 1;
    result = 0;
    for (int lane = 0; lane < 4; lane++) begin
      value = {1'b0, x[8*lane+:8]} + {1'b0, ~y[8*lane+:8]} + 9'(carry);
      result[8*lane+:8] = value[7:0];
      carry = segmented ? 1'b1 : value[8];
    end
    return result;
  endfunction
  always_comb begin
    correction_a = 0;
    correction_b = 0;
    for (int lane = 0; lane < 4; lane++) begin
      correction_a[8*lane+:8]=multiply_simd ? (multiply_a[8*lane+7] ? multiply_b[8*lane+:8]:8'b0) : (multiply_a[31] ? multiply_b[8*lane+:8]:8'b0);
      correction_b[8*lane+:8]=multiply_simd ? (multiply_b[8*lane+7] ? multiply_a[8*lane+:8]:8'b0) : (multiply_b[31] ? multiply_a[8*lane+:8]:8'b0);
    end
  end
  assign signed_high = segmented_sub(
      segmented_sub(product_high, correction_a, multiply_simd), correction_b, multiply_simd
  );
  // A single segmented adder covers all basic additive operations.
  always_comb begin
    logic [8:0] byte_sum;
    subtract = op_i == 3 || op_i == 13 || op_i == 14;
    lhs = (op_i == 13 || op_i == 14) ? 32'b0 : a_i;
    rhs = op_i == 23 ? {32{b_i[31]}} : (op_i == 13 || op_i == 14) ? a_i : b_i;
    if (subtract) rhs = ~rhs;
    carries = 0;
    sum = 0;
    carries[0] = subtract || ((op_i == 17 || op_i == 23) && carry_i);
    for (int lane = 0; lane < 4; lane++) begin
      byte_sum = {1'b0, lhs[8*lane+:8]} + {1'b0, rhs[8*lane+:8]} + 9'(carries[lane]);
      sum[8*lane+:8] = byte_sum[7:0];
      carries[lane+1] = simd_i && lane < 3 ? subtract : byte_sum[8];
    end
    carry_o = simd_i ? 1'b0 : carries[4];
  end
  for (genvar lane = 0; lane < 4; lane++) begin : g_compare
    assign byte_equal[lane] = a_i[8*lane+:8] == b_i[8*lane+:8];
    assign byte_less[lane] = a_i[8*lane+:8] < b_i[8*lane+:8];
    assign byte_signed_less[lane]=(a_i[8*lane+7]^b_i[8*lane+7]) ? a_i[8*lane+7]:byte_less[lane];
  end
  always_comb begin
    unsigned_less = 0;
    for (int lane = 0; lane < 4; lane++)
    unsigned_less = byte_less[lane] || (byte_equal[lane] && unsigned_less);
    signed_less = (a_i[31] ^ b_i[31]) ? a_i[31] : unsigned_less;
  end
  // One barrel network: its low three stages become four byte shifters;
  // the 8/16-bit stages are bypassed in SIMD mode.
  assign shift_stage[0] = a_i;
  for (genvar stage = 0; stage < 3; stage++) begin : g_byte_shift
    for (genvar bit_index = 0; bit_index < 32; bit_index++) begin : g_bit
      localparam int L = bit_index / 8, STEP = 1 << stage;
      logic left_bit, right_bit, fill_bit, enable;
      logic left_source, right_source;
      if (bit_index >= STEP) begin : g_left
        assign left_source = shift_stage[stage][bit_index-STEP];
      end else assign left_source = 0;
      if (bit_index + STEP < 32) begin : g_right
        assign right_source = shift_stage[stage][bit_index+STEP];
      end else assign right_source = 0;
      always_comb begin
        fill_bit = (op_i == 11 || op_i == 26) && (simd_i ? a_i[8*L+7] : a_i[31]);
        left_bit = left_source && (!simd_i || (bit_index - STEP) / 8 == L);
        right_bit = bit_index + STEP < 32 && (!simd_i || (bit_index + STEP) / 8 == L) ? right_source : fill_bit;
        enable = simd_i ? b_i[8*L+stage] : b_i[stage];
        shift_stage[stage+1][bit_index]=enable ? (op_i==9 ? left_bit:right_bit):shift_stage[stage][bit_index];
      end
    end
  end
  for (genvar stage = 3; stage < 5; stage++) begin : g_word_shift
    always_comb begin
      shift_stage[stage+1] = shift_stage[stage];
      if (!simd_i && b_i[stage]) begin
        if (op_i == 9) shift_stage[stage+1] = shift_stage[stage] << (1 << stage);
        else if (op_i == 11 || op_i == 26)
          shift_stage[stage+1] = $signed(shift_stage[stage]) >>> (1 << stage);
        else shift_stage[stage+1] = shift_stage[stage] >> (1 << stage);
      end
    end
  end
  always_comb begin
    pair_amount = c_i[5:0];
    pair_shifted = a_i;
    pair_mask = 0;
    if (pair_amount == 32) pair_shifted = b_i;
    else if (pair_amount != 0) pair_shifted = (a_i >> pair_amount) | (b_i << (32 - pair_amount));
    if (pair_amount != 0 && pair_amount <= 32) pair_mask = (32'b1 << (pair_amount - 1)) - 1;
    data_o = 0;
    if (simd_i) begin
      for (int lane = 0; lane < 4; lane++) begin
        logic [7:0] x, y, value, mask;
        logic [2:0] amount;
        x = a_i[8*lane+:8];
        y = b_i[8*lane+:8];
        value = 0;
        mask = 0;
        amount = y[2:0];
        case (op_i)
          0: value = x[7] ? 0 : x;
          1, 3, 13: value = sum[8*lane+:8];
          2: value = x;
          4: value = byte_signed_less[lane] ? x : y;
          5: value = byte_signed_less[lane] ? y : x;
          6: value = x & y;
          7: value = x | y;
          8: value = x ^ y;
          9, 10, 11: value = shift_stage[5][8*lane+:8];
          12: value = {7'b0, byte_equal[lane]};
          14: value = x[7] ? sum[8*lane+:8] : x;
          15: value = ~x;
          18: value = {7'b0, byte_less[lane]};
          19: value = product_high[8*lane+:8];
          20: value = signed_high[8*lane+:8];
          24: value = product_low[8*lane+:8];
          26: begin
            value = shift_stage[5][8*lane+:8];
            mask = amount == 0 ? 0 : (8'b1 << (amount - 1)) - 1;
            if (amount != 0 && x[amount-1] && ((x & mask) != 0 || value[0])) value = value + 1;
          end
          29: value = c_i[8*lane+:8];
          default: value = 0;
        endcase
        data_o[8*lane+:8] = value;
      end
    end else begin
      case (op_i)
        0: data_o = a_i[31] ? 0 : a_i;
        1, 3, 13, 16, 17, 23: data_o = sum;
        2: data_o = a_i;
        4: data_o = signed_less ? a_i : b_i;
        5: data_o = signed_less ? b_i : a_i;
        6: data_o = a_i & b_i;
        7: data_o = a_i | b_i;
        8: data_o = a_i ^ b_i;
        9, 10, 11: data_o = shift_stage[5];
        12: data_o = {31'b0, &byte_equal};
        14: data_o = a_i[31] ? sum : a_i;
        15: data_o = ~a_i;
        18: data_o = {31'b0, unsigned_less};
        19: data_o = product_high;
        20: data_o = signed_high;
        21: data_o = pair_amount <= 32 ? pair_shifted : 0;
        22: begin
          data_o = pair_shifted;
          if(pair_amount!=0 && pair_amount<=32 && a_i[pair_amount-1] && ((a_i&pair_mask)!=0 || pair_shifted[0]))
            data_o = pair_shifted + 1;
          if (pair_amount > 32) data_o = 0;
        end
        24: data_o = product_low;
        26: begin
          data_o = shift_stage[5];
          pair_mask = b_i[4:0] == 0 ? 0 : (32'b1 << (b_i[4:0] - 1)) - 1;
          if (b_i[4:0] != 0 && a_i[b_i[4:0]-1] && ((a_i & pair_mask) != 0 || data_o[0]))
            data_o = data_o + 1;
        end
        29: data_o = c_i;
        default: data_o = 0;
      endcase
    end
  end
endmodule
