// Native memory DMA, one staging register and no extra RAM/FIFO.
// mode: 0 stream->SRAM, 1 SRAM->stream, 2 SRAM copy, 3 pattern fill.
// Addresses/strides are word-aligned; rows may end with 1..3 valid bytes.
module npu_dma_channel (
  input logic clk_i, rst_ni, start_i, abort_i,
  input logic [1:0] mode_i,
  input logic [31:0] src_i, dst_i, row_bytes_i, rows_i,
  input logic [31:0] src_stride_i, dst_stride_i, fill_i, timeout_i,
  output logic busy_o, done_o, fault_o,
  output logic [3:0] fault_code_o,
  output logic [31:0] bytes_done_o, cycles_o,
  input logic rx_valid_i,
  output logic rx_ready_o,
  input logic [31:0] rx_data_i,
  input logic [3:0] rx_keep_i,
  input logic rx_last_i,
  output logic tx_valid_o,
  input logic tx_ready_i,
  output logic [31:0] tx_data_o,
  output logic [3:0] tx_keep_o,
  output logic tx_last_o, stream_abort_o,
  output logic req_o, we_o,
  output logic [3:0] be_o,
  output logic [31:0] addr_o, wdata_o,
  input logic gnt_i, rvalid_i, error_i,
  input logic [31:0] rdata_i
);
  typedef enum logic [2:0] {IDLE, RX_WAIT, READ_REQ, READ_WAIT, TX_WAIT, WRITE_REQ, WRITE_WAIT} state_t;
  state_t state_q;
  logic [1:0] mode_q;
  logic [31:0] src_q, dst_q, src_row_q, dst_row_q, value_q, fill_q;
  logic [31:0] src_stride_q, dst_stride_q, timeout_q;
  logic [13:0] row_bytes_q, remaining_q;
  logic [11:0] rows_remaining_q;
  logic [3:0] keep;
  logic [2:0] beat_bytes;
  logic last, expire, cancel, advance, write_complete;
  assign busy_o = state_q != IDLE;
  assign expire = busy_o && timeout_q != 0 && cycles_o >= timeout_q - 1'b1;
  assign cancel = abort_i || expire;
  assign beat_bytes = remaining_q >= 4 ? 3'd4 : remaining_q[2:0];
  assign keep = remaining_q >= 4 ? 4'hf : (4'hf >> (4-remaining_q[2:0]));
  assign last = rows_remaining_q == 1 && remaining_q <= 4;
  assign rx_ready_o = state_q == RX_WAIT && !cancel && rst_ni;
  assign tx_valid_o = state_q == TX_WAIT && !cancel && rst_ni;
  assign tx_data_o = value_q;
  assign tx_keep_o = keep;
  assign tx_last_o = last;
  assign req_o = (state_q == READ_REQ || state_q == WRITE_REQ) && !cancel && rst_ni;
  assign we_o = state_q == WRITE_REQ;
  assign be_o = we_o ? keep : 4'hf;
  assign addr_o = we_o ? dst_q : src_q;
  assign wdata_o = value_q;
  assign write_complete = state_q == WRITE_WAIT && rvalid_i && !error_i;
  assign advance = (state_q == TX_WAIT && tx_valid_o && tx_ready_i)
                  || (state_q == WRITE_WAIT && rvalid_i && !error_i && !cancel);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; mode_q <= 0;
      src_q <= 0; dst_q <= 0; src_row_q <= 0; dst_row_q <= 0;
      value_q <= 0; fill_q <= 0; src_stride_q <= 0; dst_stride_q <= 0; timeout_q <= 0;
      row_bytes_q <= 0; remaining_q <= 0; rows_remaining_q <= 0;
      bytes_done_o <= 0; cycles_o <= 0; done_o <= 0; fault_o <= 0;
      fault_code_o <= 0; stream_abort_o <= 0;
    end else begin
      done_o <= 0; fault_o <= 0; stream_abort_o <= 0;
      if (busy_o) cycles_o <= cycles_o + 1'b1;
      // The previous cycle's accepted write is committed even if aborted now.
      if (write_complete) bytes_done_o <= bytes_done_o + {29'b0,beat_bytes};
      if (busy_o && cancel) begin
        state_q <= IDLE; fault_o <= 1;
        fault_code_o <= abort_i ? 4'd5 : 4'd6;
        if (mode_q <= 1) stream_abort_o <= 1;
      end else begin
        case (state_q)
          IDLE: if (start_i) begin
            mode_q <= mode_i;
            src_q <= src_i; src_row_q <= src_i; dst_q <= dst_i; dst_row_q <= dst_i;
            src_stride_q <= src_stride_i; dst_stride_q <= dst_stride_i;
            row_bytes_q <= row_bytes_i[13:0]; remaining_q <= row_bytes_i[13:0];
            rows_remaining_q <= rows_i[11:0]; timeout_q <= timeout_i;
            fill_q <= fill_i; value_q <= fill_i;
            bytes_done_o <= 0; cycles_o <= 0; fault_code_o <= 0;
            state_q <= mode_i == 0 ? RX_WAIT : mode_i == 3 ? WRITE_REQ : READ_REQ;
          end
          RX_WAIT: if (rx_valid_i && rx_ready_o) begin
            if (rx_keep_i != keep || rx_last_i != last) begin
              state_q <= IDLE; fault_o <= 1; fault_code_o <= 3;
              stream_abort_o <= 1;
            end else begin value_q <= rx_data_i; state_q <= WRITE_REQ; end
          end
          READ_REQ: if (gnt_i) state_q <= READ_WAIT;
          READ_WAIT: if (rvalid_i) begin
            if (error_i) begin
              state_q <= IDLE; fault_o <= 1; fault_code_o <= 4;
              if (mode_q == 1) stream_abort_o <= 1;
            end else begin
              value_q <= rdata_i;
              state_q <= mode_q == 1 ? TX_WAIT : WRITE_REQ;
            end
          end
          WRITE_REQ: if (gnt_i) state_q <= WRITE_WAIT;
          WRITE_WAIT: if (rvalid_i && error_i) begin
            state_q <= IDLE; fault_o <= 1; fault_code_o <= 4;
            if (mode_q == 0) stream_abort_o <= 1;
          end
          default: ;
        endcase
        if (advance) begin
          if (state_q == TX_WAIT) bytes_done_o <= bytes_done_o + {29'b0,beat_bytes};
          if (last) begin state_q <= IDLE; done_o <= 1; end
          else begin
            if (remaining_q <= 4) begin
              remaining_q <= row_bytes_q;
              rows_remaining_q <= rows_remaining_q - 1'b1;
              src_row_q <= src_row_q + src_stride_q; src_q <= src_row_q + src_stride_q;
              dst_row_q <= dst_row_q + dst_stride_q; dst_q <= dst_row_q + dst_stride_q;
            end else begin
              remaining_q <= remaining_q - 4;
              src_q <= src_q + 4; dst_q <= dst_q + 4;
            end
            if (mode_q == 3) value_q <= fill_q;
            state_q <= mode_q == 0 ? RX_WAIT : mode_q == 3 ? WRITE_REQ : READ_REQ;
          end
        end
      end
    end
  end
endmodule
