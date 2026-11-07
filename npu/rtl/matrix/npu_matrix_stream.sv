// Matrix operand/result feeder. GEMM loops and memory ownership are outside arithmetic.
// Dense signed integer GEMM: D=op(A)*op(B), optional D+=.
// flags: bit0 transpose A, bit1 transpose B, bit2 accumulate D,
// bit3 packed inputs, bit4 INT16 (otherwise INT8). D is always INT32.
// Legacy flags=0 stores one INT8 in the low byte of each 32-bit word.
module npu_matrix_stream #(
  parameter bit GATHER = 0
) (

  output logic [2:0] compute_extra_valid_o,
  output logic signed [2:0][15:0] compute_extra_a_o,
  compute_extra_b_o,
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
  output logic signed [15:0] compute_a_o,
  compute_b_o,
  output logic [31:0] compute_addend_o,
  input logic compute_ready_i,
  compute_result_valid_i,
  output logic compute_result_ready_o,
  input logic [31:0] compute_result_data_i,

  input logic clk_i,
  rst_ni,
  start_i,
  input logic [31:0] a_i,
  b_i,
  d_i,
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
  logic batch_ready, batch_valid, batch_req;
  logic [31:0] batch_addr;
  logic [2:0][31:0] batch_addresses, batch_data;
  logic [2:0] batch_mask, batch_error;

  typedef enum logic [3:0] {
    IDLE,
    A_REQ,
    A_WAIT,
    B_REQ,
    B_WAIT,
    C_REQ,
    C_WAIT,
    D_REQ,
    D_WAIT
  } state_t;
  state_t state_q;
  logic [31:0] a_row, b_base, b_col, a_ptr, b_ptr, d_ptr;
  logic [6:0] a_inner, b_inner, a_row_step, b_col_step;
  logic [4:0] m_q, n_q, k_q, row_q, col_q, inner_q;
  logic [4:0] flags_q;
  logic signed [15:0] a_val;
  logic response_error;
  logic [2:0] chunk;
  always_comb begin
    chunk = 1;
    if (GATHER && flags_q[3] && a_inner == (flags_q[4] ? 2 : 1) && b_inner == (flags_q[4] ? 2 : 1)) begin
      for (int count = 2; count <= 4; count++)
      if (count <= int'(k_q)-int'(inner_q) && int'(a_ptr[1:0])+count*(flags_q[4] ? 2 : 1)<=4 && int'(b_ptr[1:0])+count*(flags_q[4] ? 2 : 1)<=4)
        chunk = 3'(count);
    end
    compute_extra_valid_o = 0;
    compute_extra_a_o = 0;
    compute_extra_b_o = 0;
    for (int p = 0; p < 3; p++) begin
      compute_extra_valid_o[p] = p + 1 < chunk;
      compute_extra_a_o[p] = unpack_value(
          batch_data[0], 2'(int'(a_ptr[1:0]) + (p + 1) * (flags_q[4] ? 2 : 1)), flags_q[4]);
      compute_extra_b_o[p] = unpack_value(
          batch_data[1], 2'(int'(b_ptr[1:0]) + (p + 1) * (flags_q[4] ? 2 : 1)), flags_q[4]);
    end
  end


  npu_multi_read #(
    .GATHER(GATHER)
  ) i_operand_read (
    .clk_i,
    .rst_ni,
    .valid_i (state_q == A_REQ),
    .ready_o (batch_ready),
    .mask_i  (batch_mask),
    .addr_i  (batch_addresses),
    .valid_o (batch_valid),
    .ready_i (state_q == A_WAIT && (compute_ready_i || |batch_error)),
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
    .gnt_i   (gnt_i && state_q == A_WAIT),
    .rvalid_i(rvalid_i && state_q == A_WAIT),
    .error_i,
    .rdata_i
  );
  assign batch_mask = 3'b011;
  assign batch_addresses = {32'b0, {b_ptr[31:2], 2'b0}, {a_ptr[31:2], 2'b0}};

  function automatic logic signed [15:0] unpack_value(input logic [31:0] word,
                                                      input logic [1:0] offset, input logic wide);
    logic [31:0] shifted;
    shifted = word >> ({offset, 3'b0});
    return wide ? $signed(shifted[15:0]) : $signed({{8{shifted[7]}}, shifted[7:0]});
  endfunction
  assign compute_a_o = unpack_value(batch_data[0], a_ptr[1:0], flags_q[4]);
  assign compute_b_o = unpack_value(batch_data[1], b_ptr[1:0], flags_q[4]);
  assign compute_addend_o = rdata_i;
  assign compute_multiply_o = state_q == A_WAIT;
  assign compute_valid_o = (state_q == A_WAIT && batch_valid && !(|batch_error)) || (state_q == C_WAIT && rvalid_i && !error_i);
  assign compute_emit_o = state_q == C_WAIT || (inner_q + chunk == k_q && !flags_q[2]);
  assign compute_result_ready_o = state_q == D_REQ && gnt_i;
  assign compute_flush_o = response_error || (state_q==IDLE && start_i) || (state_q==D_WAIT && rvalid_i);

  // Only WAIT states own a reply. Ignore stray error/rvalid in IDLE or while
  // waiting for a request grant; a failed reply produces one fault pulse.
  assign response_error = (state_q == A_WAIT && batch_valid && |batch_error) || (rvalid_i && error_i && (state_q == C_WAIT || state_q == D_WAIT));
  assign busy_o = state_q != IDLE;
  assign req_o = (state_q == A_WAIT && batch_req) || state_q == C_REQ || (state_q == D_REQ && compute_result_valid_i);
  assign we_o = state_q == D_REQ;
  assign addr_o = state_q == A_WAIT ? batch_addr : d_ptr;
  assign wdata_o = compute_result_data_i;
  // A start snapshots the descriptor only in IDLE. Validation belongs to MMIO;
  // each granted transfer must receive a response, including writes. A fault
  // stops this job but does not roll back writes already accepted by memory.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      done_o <= 0;
      fault_o <= 0;
      a_row <= 0;
      b_base <= 0;
      b_col <= 0;
      a_ptr <= 0;
      b_ptr <= 0;
      d_ptr <= 0;
      a_inner <= 0;
      b_inner <= 0;
      a_row_step <= 0;
      b_col_step <= 0;
      m_q <= 0;
      n_q <= 0;
      k_q <= 0;
      row_q <= 0;
      col_q <= 0;
      inner_q <= 0;
      flags_q <= 0;
      a_val <= 0;
    end else begin
      done_o <= 0;
      fault_o <= 0;
      if (response_error) begin
        state_q <= IDLE;
        fault_o <= 1;
      end else
        case (state_q)
          IDLE:
          if (start_i) begin
            a_row <= a_i;
            b_base <= b_i;
            b_col <= b_i;
            a_ptr <= a_i;
            b_ptr <= b_i;
            d_ptr <= d_i;
            m_q <= m_i;
            n_q <= n_i;
            k_q <= k_i;
            row_q <= 0;
            col_q <= 0;
            inner_q <= 0;
            flags_q <= flags_i;
            a_inner <= (flags_i[0] ? {2'b0, m_i} : 7'd1) << (flags_i[3] ? (flags_i[4] ? 1 : 0) : 2);
            b_inner <= (flags_i[1] ? 7'd1 : {2'b0, n_i}) << (flags_i[3] ? (flags_i[4] ? 1 : 0) : 2);
            a_row_step<=(flags_i[0] ? 7'd1 : {2'b0,k_i}) << (flags_i[3] ? (flags_i[4] ? 1 : 0) : 2);
            b_col_step<=(flags_i[1] ? {2'b0,k_i} : 7'd1) << (flags_i[3] ? (flags_i[4] ? 1 : 0) : 2);
            state_q <= A_REQ;
          end
          A_REQ: if (batch_ready) state_q <= A_WAIT;
          A_WAIT:
          if (batch_valid && compute_ready_i) begin
            if (inner_q + chunk == k_q) state_q <= flags_q[2] ? C_REQ : D_REQ;
            else begin
              inner_q <= inner_q + chunk;
              a_ptr <= data_advance(a_ptr, 32'(a_inner) * 32'(chunk));
              b_ptr <= data_advance(b_ptr, 32'(b_inner) * 32'(chunk));
              state_q <= A_REQ;
            end
          end
          C_REQ: if (gnt_i) state_q <= C_WAIT;
          C_WAIT:
          if (rvalid_i && compute_ready_i) begin
            state_q <= D_REQ;
          end
          D_REQ: if (gnt_i) state_q <= D_WAIT;
          D_WAIT:
          if (rvalid_i) begin
            if (row_q + 1'b1 == m_q && col_q + 1'b1 == n_q) begin
              done_o <= 1;
              state_q <= IDLE;
            end else begin
              d_ptr <= data_advance(d_ptr, 4);
              inner_q <= 0;
              state_q <= A_REQ;
              if (col_q + 1'b1 == n_q) begin
                row_q <= row_q + 1'b1;
                col_q <= 0;
                a_row <= data_advance(a_row, a_row_step);
                a_ptr <= data_advance(a_row, a_row_step);
                b_col <= b_base;
                b_ptr <= b_base;
              end else begin
                col_q <= col_q + 1'b1;
                a_ptr <= a_row;
                b_col <= data_advance(b_col, b_col_step);
                b_ptr <= data_advance(b_col, b_col_step);
              end
            end
          end
          default: state_q <= IDLE;
        endcase
    end
  end
endmodule
