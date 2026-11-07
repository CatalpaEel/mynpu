// Tiled GEMM feeder for the pure 4x4 outer-product core.
// Eight operand words retain the current A-column/B-row fragments across K.
// Matching packed lanes share a word fetch; up to three distinct words use RF
// gather together, and SRAM/FIFO reads use the original single ordinary port.
// Strides are in elements: zero selects the original dense layout.
module npu_matrix_stream #(
  parameter bit GATHER = 0
) (
  output logic [2:0] gather_req_o,
  output logic [2:0][31:0] gather_addr_o,
  input logic [2:0] gather_gnt_i,
  gather_valid_i,
  gather_error_i,
  input logic [2:0][31:0] gather_data_i,
  output logic compute_valid_o,
  compute_flush_o,
  compute_multiply_o,
  compute_emit_o,
  output logic [3:0] compute_row_mask_o,
  compute_col_mask_o,
  compute_index_o,
  output logic signed [3:0][15:0] compute_a_o,
  compute_b_o,
  output logic [31:0] compute_addend_o,
  input logic compute_ready_i,
  compute_result_valid_i,
  output logic compute_result_ready_o,
  input logic [31:0] compute_result_data_i,
  input logic quant_enable_i,
  quant_pack_i,
  input logic [31:0] quant_dst_i,
  output logic [3:0] be_o,
  input logic clk_i,
  rst_ni,
  start_i,
  input logic [31:0] a_i,
  b_i,
  d_i,
  input logic [15:0] lda_i,
  ldb_i,
  input logic [4:0] m_i,
  n_i,
  k_i,
  flags_i,
  output logic busy_o,
  done_o,
  fault_o,
  req_o,
  we_o,
  output logic [31:0] addr_o,
  wdata_o,
  input logic gnt_i,
  rvalid_i,
  error_i,
  input logic [31:0] rdata_i
);
  import npu_addr_pkg::*;
  typedef enum logic [3:0] {
    IDLE,
    CLEAR,
    FETCH,
    WAIT_WORDS,
    C_REQ,
    C_WAIT,
    EMIT,
    D_REQ,
    D_WAIT
  } state_t;
  state_t state;
  logic [31:0] a_base, b_base, d_base;
  logic [15:0] lda, ldb;
  logic [4:0] m, n, k, flags, tile_row, tile_col, inner;
  logic [1:0] out_r, out_c;
  logic [2:0] rows, cols, element_shift;
  logic scalar_stream;
  logic [7:0] word_valid, needed;
  logic [7:0][31:0] operand_addr, word_data;
  logic [7:0][12:0] word_tag;
  logic [2:0] batch_mask, batch_error;
  logic [2:0][31:0] batch_addresses, batch_data;
  logic [2:0][7:0] targets, reply_targets;
  logic batch_ready, batch_valid, batch_req, all_available, response_error;
  logic [31:0] batch_addr, d_address, output_address, linear_index;
  // Stream endpoints preserve the original scalar traversal/pop ordering.
  assign scalar_stream = is_stream_address(
      a_base
  ) || is_stream_address(
      b_base
  ) || is_stream_address(
      d_base
  ) || (quant_enable_i && is_stream_address(
      quant_dst_i
  ));
  assign rows = scalar_stream ? 1 : m - tile_row >= 4 ? 4 : 3'(m - tile_row);
  assign cols = scalar_stream ? 1 : n - tile_col >= 4 ? 4 : 3'(n - tile_col);
  assign element_shift = flags[3] ? (flags[4] ? 1 : 0) : 2;
  assign linear_index = (32'(tile_row) + 32'(out_r)) * 32'(n) + 32'(tile_col) + 32'(out_c);
  assign d_address = data_advance(d_base, linear_index << 2);
  assign output_address = quant_enable_i ? data_advance(
      quant_dst_i, linear_index << (quant_pack_i ? 0 : 2)
  ) : d_address;
  assign all_available = needed == 0;
  function automatic logic signed [15:0] unpack_value(input logic [31:0] word,
                                                      input logic [1:0] offset, input logic wide);
    logic [31:0] shifted;
    shifted = word >> {offset, 3'b0};
    return wide ? $signed(shifted[15:0]) : $signed({{8{shifted[7]}}, shifted[7:0]});
  endfunction
  always_comb begin
    logic [7:0] covered;
    logic found;
    logic [31:0] index;
    needed = 0;
    operand_addr = 0;
    compute_a_o = 0;
    compute_b_o = 0;
    compute_row_mask_o = 0;
    compute_col_mask_o = 0;
    for (int lane = 0; lane < 4; lane++) begin
      index=flags[0] ? 32'(inner)*32'(lda)+32'(tile_row)+32'(lane) : (32'(tile_row)+32'(lane))*32'(lda)+32'(inner);
      operand_addr[lane] = data_advance(a_base, index << element_shift);
      index=flags[1] ? (32'(tile_col)+32'(lane))*32'(ldb)+32'(inner) : 32'(inner)*32'(ldb)+32'(tile_col)+32'(lane);
      operand_addr[4+lane] = data_advance(b_base, index << element_shift);
      compute_row_mask_o[lane] = lane < int'(rows);
      compute_col_mask_o[lane] = lane < int'(cols);
      needed[lane]=lane<int'(rows) && !(word_valid[lane] && word_tag[lane]==operand_addr[lane][14:2]);
      needed[4+lane]=lane<int'(cols) && !(word_valid[4+lane] && word_tag[4+lane]==operand_addr[4+lane][14:2]);
      compute_a_o[lane] = unpack_value(word_data[lane], operand_addr[lane][1:0], flags[4]);
      compute_b_o[lane] = unpack_value(word_data[4+lane], operand_addr[4+lane][1:0], flags[4]);
    end
    covered = ~needed;
    batch_mask = 0;
    batch_addresses = 0;
    targets = 0;
    for (int p = 0; p < 3; p++) begin
      found = 0;
      for (int lane = 0; lane < 8; lane++)
      if (!covered[lane] && !found) begin
        found = 1;
        batch_mask[p] = 1;
        batch_addresses[p] = {operand_addr[lane][31:2], 2'b0};
        for (int other = 0; other < 8; other++)
        if (needed[other] && (other == lane || (!is_stream_address(
                operand_addr[lane]
            ) && operand_addr[other][31:2] == operand_addr[lane][31:2]))) begin
          targets[p][other] = 1;
          covered[other] = 1;
        end
      end
    end
  end
  npu_multi_read #(
    .GATHER(GATHER)
  ) i_operand_read (
    .clk_i,
    .rst_ni,
    .valid_i (state == FETCH && !all_available),
    .ready_o (batch_ready),
    .mask_i  (batch_mask),
    .addr_i  (batch_addresses),
    .valid_o (batch_valid),
    .ready_i (state == WAIT_WORDS),
    .data_o  (batch_data),
    .error_o (batch_error),
    .gather_req_o,
    .gather_addr_o,
    .gather_gnt_i,
    .gather_valid_i,
    .gather_error_i,
    .gather_data_i,
    .req_o   (batch_req),
    .addr_o  (batch_addr),
    .gnt_i   (gnt_i && state == WAIT_WORDS),
    .rvalid_i(rvalid_i && state == WAIT_WORDS),
    .error_i,
    .rdata_i
  );
  assign response_error=(state==WAIT_WORDS && batch_valid && |batch_error) ||
    (rvalid_i && error_i && (state==C_WAIT || state==D_WAIT));
  assign compute_valid_o=(state==FETCH && all_available) || state==EMIT || (state==C_WAIT && rvalid_i && !error_i);
  assign compute_multiply_o = state == FETCH;
  assign compute_emit_o = state == EMIT || state == C_WAIT;
  assign compute_index_o = {out_r, out_c};
  assign compute_addend_o = state == C_WAIT ? rdata_i : 0;
  assign compute_flush_o = state == CLEAR || response_error;
  assign compute_result_ready_o = state == D_REQ && gnt_i;
  assign busy_o = state != IDLE;
  assign req_o=(state==WAIT_WORDS && batch_req) || state==C_REQ || (state==D_REQ && compute_result_valid_i);
  assign we_o = state == D_REQ;
  assign addr_o=state==WAIT_WORDS ? batch_addr : state==D_REQ ? (quant_pack_i ? {output_address[31:2],2'b0}:output_address):d_address;
  assign wdata_o=quant_pack_i ? {24'b0,compute_result_data_i[7:0]}<<{output_address[1:0],3'b0}:compute_result_data_i;
  assign be_o = state == D_REQ && quant_pack_i ? 4'b1 << output_address[1:0] : 4'hf;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state <= IDLE;
      done_o <= 0;
      fault_o <= 0;
      a_base <= 0;
      b_base <= 0;
      d_base <= 0;
      lda <= 0;
      ldb <= 0;
      m <= 0;
      n <= 0;
      k <= 0;
      flags <= 0;
      tile_row <= 0;
      tile_col <= 0;
      inner <= 0;
      out_r <= 0;
      out_c <= 0;
      word_valid <= 0;
      word_data <= 0;
      word_tag <= 0;
      reply_targets <= 0;
    end else begin
      done_o <= 0;
      fault_o <= 0;
      if (response_error) begin
        state <= IDLE;
        fault_o <= 1;
      end else
        case (state)
          IDLE:
          if (start_i) begin
            a_base <= a_i;
            b_base <= b_i;
            d_base <= d_i;
            m <= m_i;
            n <= n_i;
            k <= k_i;
            flags <= flags_i;
            lda <= lda_i != 0 ? lda_i : flags_i[0] ? 16'(m_i) : 16'(k_i);
            ldb <= ldb_i != 0 ? ldb_i : flags_i[1] ? 16'(k_i) : 16'(n_i);
            tile_row <= 0;
            tile_col <= 0;
            state <= CLEAR;
          end
          CLEAR: begin
            word_valid <= 0;
            inner <= 0;
            out_r <= 0;
            out_c <= 0;
            state <= k == 0 ? C_REQ : FETCH;
          end
          FETCH:
          if (all_available) begin
            if (compute_ready_i) begin
              if (inner + 1 == k) state <= flags[2] ? C_REQ : EMIT;
              else inner <= inner + 1;
            end
          end else if (batch_ready) begin
            reply_targets <= targets;
            state <= WAIT_WORDS;
          end
          WAIT_WORDS:
          if (batch_valid) begin
            for (int p = 0; p < 3; p++)
            for (int lane = 0; lane < 8; lane++)
            if (reply_targets[p][lane]) begin
              word_data[lane] <= batch_data[p];
              word_tag[lane] <= operand_addr[lane][14:2];
              word_valid[lane] <= 1;
            end
            state <= FETCH;
          end
          C_REQ: if (gnt_i) state <= C_WAIT;
          C_WAIT: if (rvalid_i && compute_ready_i) state <= D_REQ;
          EMIT: if (compute_ready_i) state <= D_REQ;
          D_REQ: if (gnt_i) state <= D_WAIT;
          D_WAIT:
          if (rvalid_i) begin
            if (32'(out_c) + 1 < 32'(cols)) begin
              out_c <= out_c + 1;
              state <= flags[2] ? C_REQ : EMIT;
            end else if (32'(out_r) + 1 < 32'(rows)) begin
              out_r <= out_r + 1;
              out_c <= 0;
              state <= flags[2] ? C_REQ : EMIT;
            end else if (tile_col + 5'(cols) < n) begin
              tile_col <= tile_col + 5'(cols);
              state <= CLEAR;
            end else if (tile_row + 5'(rows) < m) begin
              tile_row <= tile_row + 5'(rows);
              tile_col <= 0;
              state <= CLEAR;
            end else begin
              state <= IDLE;
              done_o <= 1;
            end
          end
          default: state <= IDLE;
        endcase
    end
  end
endmodule
