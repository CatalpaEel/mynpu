// INT32 ReLU (op=0) or wrapping INT32 add (op=1). Exact in-place supported.
module npu_vector (
  input logic clk_i, rst_ni, start_i,
  input logic [31:0] a_i, b_i, d_i,
  input logic [10:0] len_i,
  input logic op_i,
  output logic busy_o, done_o, fault_o,
  output logic req_o, we_o,
  output logic [31:0] addr_o, wdata_o,
  input logic gnt_i, rvalid_i, error_i,
  input logic [31:0] rdata_i
);
  typedef enum logic [2:0] {IDLE, A_REQ, A_WAIT, B_REQ, B_WAIT, D_REQ, D_WAIT} state_t;
  state_t state_q;
  logic [31:0] a_q, b_q, d_q, value_q;
  logic [10:0] remaining_q;
  logic op_q;
  assign busy_o = state_q != IDLE;
  assign req_o = state_q == A_REQ || state_q == B_REQ || state_q == D_REQ;
  assign we_o = state_q == D_REQ;
  assign addr_o = state_q == A_REQ ? a_q : state_q == B_REQ ? b_q : d_q;
  assign wdata_o = value_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; done_o <= 0; fault_o <= 0;
      a_q <= 0; b_q <= 0; d_q <= 0; value_q <= 0; remaining_q <= 0; op_q <= 0;
    end else begin
      done_o <= 0; fault_o <= 0;
      case (state_q)
        IDLE: if (start_i) begin
          a_q <= a_i; b_q <= b_i; d_q <= d_i;
          remaining_q <= len_i; op_q <= op_i; state_q <= A_REQ;
        end
        A_REQ: if (gnt_i) state_q <= A_WAIT;
        A_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else begin
            value_q <= op_q ? rdata_i : (rdata_i[31] ? 32'b0 : rdata_i);
            state_q <= op_q ? B_REQ : D_REQ;
          end
        end
        B_REQ: if (gnt_i) state_q <= B_WAIT;
        B_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else begin value_q <= value_q + rdata_i; state_q <= D_REQ; end
        end
        D_REQ: if (gnt_i) state_q <= D_WAIT;
        D_WAIT: if (rvalid_i) begin
          if (error_i) begin state_q <= IDLE; fault_o <= 1; end
          else if (remaining_q == 1) begin done_o <= 1; state_q <= IDLE; end
          else begin
            remaining_q <= remaining_q - 1'b1;
            a_q <= a_q + 4; b_q <= b_q + 4; d_q <= d_q + 4;
            state_q <= A_REQ;
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
