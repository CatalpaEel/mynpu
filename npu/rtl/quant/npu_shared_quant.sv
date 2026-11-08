// Two direct result inputs, one shared multiplier/round/clamp pipeline.
// The producer holds its result until the filtered output is consumed. This
// preserves the existing stream's result metadata and propagates backpressure.
module npu_shared_quant (
  input logic clk_i,
  rst_ni,
  input logic csr_req_i,
  csr_we_i,
  input logic [7:0] csr_addr_i,
  input logic [31:0] csr_wdata_i,
  output logic [31:0] csr_rdata_o,
  output logic csr_error_o,
  input logic [1:0] blocked_i,
  flush_i,
  valid_i,
  output logic [1:0] ready_o,
  valid_o,
  input logic [1:0] ready_i,
  input logic [1:0][31:0] data_i,
  output logic [1:0][31:0] data_o,
  output logic [1:0] enable_o,
  pack_o,
  output logic [1:0][31:0] dst_o
);
  // Per-source settings are immutable while that source owns queued/active work.
  // 00 control(enable,pack8),04 multiplier,08 scaled bias,0c shift(0..32),
  // 10 zero point,14 clamp min,18 clamp max,1c INT32 input correction,20 dest.
  logic [1:0][8:0][31:0] cfg;
  logic [2:0] state;
  logic owner, last_owner, selected;
  logic signed [63:0] product, biased;
  logic signed [31:0] bias, zero, lower, upper;
  logic [5:0] shift;
  logic [31:0] result, corrected;
  logic known, writable, valid_write;
  logic [3:0] word_index;
  logic source;
  assign source = csr_addr_i[6];
  assign word_index = csr_addr_i[5:2];
  for (genvar p = 0; p < 2; p++) begin
    assign enable_o[p] = cfg[p][0][0];
    assign pack_o[p] = cfg[p][0][1] && cfg[p][0][0];
    assign dst_o[p] = cfg[p][8];
  end
  always_comb begin
    csr_rdata_o = 0;
    known = 1;
    writable = 1;
    valid_write = 1;
    if (csr_addr_i == 'h80) begin
      csr_rdata_o = 'h51543031;
      writable = 0;
    end else if (csr_addr_i[7] || word_index > 8 || csr_addr_i[1:0] != 0) known = 0;
    else begin
      csr_rdata_o = cfg[source][word_index];
      case (word_index)
        0:
        valid_write=csr_wdata_i<=3 && (!csr_wdata_i[1] || csr_wdata_i[0]) &&
          (!csr_wdata_i[0] || ($signed(cfg[source][5]) <= $signed(cfg[source][6]) &&
            (csr_wdata_i[1] ? !npu_addr_pkg::is_stream_address(cfg[source][8]) :
             cfg[source][8][1:0] == 0)));
        3: valid_write = csr_wdata_i <= 32;
        8: valid_write = npu_addr_pkg::data_range_ok(csr_wdata_i, 1);
        default: ;
      endcase
    end
    csr_error_o = !known || (csr_we_i && (!writable || !valid_write || blocked_i[source]));
    selected = valid_i[!last_owner] ? !last_owner : last_owner;
    corrected = data_i[selected] + cfg[selected][7];  // intentional INT32 wrap
    ready_o = 0;
    valid_o = 0;
    data_o = 0;
    if (state == 2 && !flush_i[owner]) begin
      valid_o[owner] = 1;
      data_o[owner] = result;
      ready_o[owner] = ready_i[owner];
    end
  end
  always_comb begin
    logic signed [31:0] rounded;
    logic [31:0] mask;
    logic signed [31:0] translated;
    // CSR validation limits shift to 0..32; only the low result word and
    // low 32 discarded bits affect rounding, including INT32 wrap.
    rounded = 32'(biased >>> shift);
    mask = shift == 0 ? 0 : (32'b1 << (shift - 1)) - 1;
    if (shift != 0 && biased[5'(shift-1)] && ((biased[31:0] & mask) != 0 || rounded[0]))
      rounded = rounded + 1;
    translated = 32'(rounded) + zero;  // match vector low-word and zero-point wrap
    result = translated < lower ? lower : translated > upper ? upper : translated;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cfg <= 0;
      state <= 0;
      owner <= 0;
      last_owner <= 1;
      product <= 0;
      biased <= 0;
      bias <= 0;
      zero <= 0;
      lower <= 0;
      upper <= 0;
      shift <= 0;
    end else begin
      if (csr_req_i && csr_we_i && !csr_error_o) cfg[source][word_index] <= csr_wdata_i;
      if (state != 0 && flush_i[owner]) state <= 0;
      else
        case (state)
          0:
          if (valid_i[selected] && !flush_i[selected]) begin
            owner <= selected;
            product <= $signed(corrected) * $signed(cfg[selected][1]);
            bias <= cfg[selected][2];
            shift <= cfg[selected][3][5:0];
            zero <= cfg[selected][4];
            lower <= cfg[selected][5];
            upper <= cfg[selected][6];
            state <= 1;
          end
          1: begin
            biased <= product + {{32{bias[31]}}, bias};
            state <= 2;
          end
          2:
          if (ready_i[owner]) begin
            state <= 0;
            last_owner <= owner;
          end
          default: state <= 0;
        endcase
    end
  end
endmodule
