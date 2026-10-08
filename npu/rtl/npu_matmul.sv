// Sequential MxK * KxN, row-major, one signed INT8 in each 32-bit word.
// One shared-memory port and one signed multiplier; output signed INT32.
module npu_matmul (
  input logic clk_i, rst_ni, start_i,
  input logic [31:0] a_i, b_i, d_i,
  input logic [4:0] m_i, n_i, k_i,
  output logic busy_o, done_o, fault_o,
  output logic req_o, we_o,
  output logic [31:0] addr_o, wdata_o,
  input logic gnt_i, rvalid_i, error_i,
  input logic [31:0] rdata_i
);
  typedef enum logic [2:0] {IDLE, A_REQ, A_WAIT, B_REQ, B_WAIT, D_REQ, D_WAIT} state_t;
  state_t state_q;
  logic [31:0] a_q, b_q, a_ptr_q, b_ptr_q, d_ptr_q;
  logic [4:0] m_q, n_q, k_q, row_q, col_q, inner_q;
  logic signed [7:0] a_val_q;
  logic signed [31:0] accum_q;
  logic signed [15:0] product;
  assign product = a_val_q * $signed(rdata_i[7:0]);
  assign busy_o = state_q != IDLE;
  assign req_o = state_q == A_REQ || state_q == B_REQ || state_q == D_REQ;
  assign we_o = state_q == D_REQ;
  assign addr_o = state_q == A_REQ ? a_ptr_q : state_q == B_REQ ? b_ptr_q : d_ptr_q;
  assign wdata_o = accum_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; done_o <= 0; fault_o <= 0;
      a_q <= 0; b_q <= 0;
      a_ptr_q <= 0; b_ptr_q <= 0; d_ptr_q <= 0;
      m_q <= 0; n_q <= 0; k_q <= 0;
      row_q <= 0; col_q <= 0; inner_q <= 0;
      a_val_q <= 0; accum_q <= 0;
    end else begin
      done_o <= 0; fault_o <= 0;
      case (state_q)
        IDLE: if (start_i) begin
          a_q <= a_i; b_q <= b_i;
          a_ptr_q <= a_i; b_ptr_q <= b_i; d_ptr_q <= d_i;
          m_q <= m_i; n_q <= n_i; k_q <= k_i;
          row_q <= 0; col_q <= 0; inner_q <= 0;
          accum_q <= 0; state_q <= A_REQ;
        end
        A_REQ: if (gnt_i) state_q <= A_WAIT;
        A_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else begin a_val_q <= rdata_i[7:0]; state_q <= B_REQ; end
        end
        B_REQ: if (gnt_i) state_q <= B_WAIT;
        B_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else begin
            accum_q <= accum_q + {{16{product[15]}}, product};
            if (inner_q + 1'b1 == k_q) state_q <= D_REQ;
            else begin
              inner_q <= inner_q + 1'b1;
              a_ptr_q <= a_ptr_q + 4;
              b_ptr_q <= b_ptr_q + ({27'b0, n_q} << 2);
              state_q <= A_REQ;
            end
          end
        end
        D_REQ: if (gnt_i) state_q <= D_WAIT;
        D_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else if (row_q + 1'b1 == m_q && col_q + 1'b1 == n_q) begin
            done_o <= 1; state_q <= IDLE;
          end else begin
            d_ptr_q <= d_ptr_q + 4;
            inner_q <= 0; accum_q <= 0; state_q <= A_REQ;
            if (col_q + 1'b1 == n_q) begin
              row_q <= row_q + 1'b1; col_q <= 0;
              a_q <= a_q + ({27'b0, k_q} << 2);
              a_ptr_q <= a_q + ({27'b0, k_q} << 2);
              b_ptr_q <= b_q;
            end else begin
              col_q <= col_q + 1'b1;
              a_ptr_q <= a_q;
              b_ptr_q <= b_q + ({27'b0, col_q} << 2) + 4;
            end
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
