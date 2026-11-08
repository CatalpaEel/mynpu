// Two direct result inputs, one shared multiplier/round/clamp pipeline.
// Two elastic arithmetic stages. Input ready acknowledges parameter sampling;
// each producer retains matching output metadata until filtered consumption.
module npu_shared_quant (
  input logic clk_i,
  rst_ni,
  input logic csr_req_i,
  csr_we_i,
  input logic [7:0] csr_addr_i,
  input logic [31:0] csr_wdata_i,
  output logic [31:0] csr_rdata_o,
  output logic csr_error_o,
  input logic [1:0][3:0] cancelled_i,
  input logic [1:0][3:0] written_i,
  write_fault_i,
  input logic [1:0] flush_i,
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
  // Per-source settings are software-owned and may change while queued/active.
  // Arithmetic is sampled per accepted result; enable/pack/dst remain live.
  // 00 control(enable,pack8),04 multiplier,08 scaled bias,0c shift(0..32),
  // 10 zero point,14 clamp min,18 clamp max,1c INT32 input correction,20 dest.
  logic [1:0][8:0][31:0] cfg;
  // Monotonic modulo-2^32 observation only; ACK does not reset counters.
  logic [1:0][31:0] accepted, issued, written, write_faults, flushed, write_cancelled;
  logic [2:0] state;
  logic owner, last_owner, selected, owner0, valid0, valid1, advance0, advance1, sample;
  logic [5:0] shift0;
  logic signed [31:0] zero0, lower0, upper0;
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
    selected = (valid_i[!last_owner] && !flush_i[!last_owner]) ? !last_owner : last_owner;
    corrected = data_i[selected] + cfg[selected][7];
    state = valid1 ? 3'd2 : valid0 ? 3'd1 : 3'd0;
    advance1 = !valid1 || ready_i[owner] || flush_i[owner];
    advance0 = !valid0 || advance1 || flush_i[owner0];
    ready_o = 0;
    if (advance0 && !flush_i[selected]) ready_o[selected] = 1;
    sample = valid_i[selected] && ready_o[selected];
    valid_o = 0;
    data_o = 0;
    if (valid1 && !flush_i[owner]) begin
      valid_o[owner] = 1;
      data_o[owner] = result;
    end
    csr_rdata_o = 0;
    known = 1;
    writable = 1;
    valid_write = 1;
    if (csr_addr_i == 'h80) begin
      csr_rdata_o = 'h51543031;
      writable = 0;
    end else if (csr_addr_i[7] || csr_addr_i[1:0] != 0) known = 0;
    else begin
      if (word_index <= 8) csr_rdata_o = cfg[source][word_index];
      else begin
        writable = 0;
        case (word_index)
          9: csr_rdata_o = accepted[source];
          10: csr_rdata_o = issued[source];
          11: csr_rdata_o = written[source];
          12: csr_rdata_o = write_faults[source];
          13: csr_rdata_o = flushed[source];
          14:
          csr_rdata_o = {
            17'b0,
            (valid_o[source] && ready_i[source]),
            (sample && selected == source),
            (state != 0 && owner),
            state,
            (|write_fault_i[source]),
            (|written_i[source]),
            flush_i[source],
            ready_i[source],
            valid_o[source],
            valid_i[source],
            ((valid0 && owner0 == source) || (valid1 && owner == source)),
            pack_o[source],
            enable_o[source]
          };
          15: csr_rdata_o = write_cancelled[source];
          default: ;
        endcase
      end
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
    csr_error_o = !known || (csr_we_i && (!writable || !valid_write));

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
      write_cancelled <= 0;
      accepted <= 0;
      issued <= 0;
      written <= 0;
      write_faults <= 0;
      flushed <= 0;
      cfg <= 0;
      valid0 <= 0;
      valid1 <= 0;
      owner0 <= 0;
      shift0 <= 0;
      zero0 <= 0;
      lower0 <= 0;
      upper0 <= 0;
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
      for (int p = 0; p < 2; p++) begin
        write_cancelled[p] <= write_cancelled[p] + 32'(cancelled_i[p]);
        written[p] <= written[p] + 32'(written_i[p]);
        write_faults[p] <= write_faults[p] + 32'(write_fault_i[p]);
        if (valid_o[p] && ready_i[p]) issued[p] <= issued[p] + 1;
      end
      if (sample) accepted[selected] <= accepted[selected] + 1;
      for (int p = 0; p < 2; p++) begin
        if (flush_i[p])
          flushed[p] <= flushed[p] + 32'(valid0 && owner0 == 1'(p)) + 32'(valid1 && owner == 1'(p));
      end
      if (csr_req_i && csr_we_i && !csr_error_o) cfg[source][word_index] <= csr_wdata_i;
      if (advance1) begin
        valid1 <= valid0 && !flush_i[owner0];
        if (valid0 && !flush_i[owner0]) begin
          biased <= product + {{32{bias[31]}}, bias};
          owner <= owner0;
          shift <= shift0;
          zero <= zero0;
          lower <= lower0;
          upper <= upper0;
        end
      end
      if (advance0) begin
        valid0 <= sample;
        if (sample) begin
          owner0 <= selected;
          last_owner <= selected;
          product <= $signed(corrected) * $signed(cfg[selected][1]);
          bias <= cfg[selected][2];
          shift0 <= cfg[selected][3][5:0];
          zero0 <= cfg[selected][4];
          lower0 <= cfg[selected][5];
          upper0 <= cfg[selected][6];
        end
      end
    end
  end
endmodule
