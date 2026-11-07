// Vector operand issuer and xbar load/store adapter. Program/RF state is external to the ALU.
// One shared vector ALU. Direct INT32 operations retain the original ABI.
// Program jobs replay MMIO-configured generic operations on four 32-bit
// temporaries; only r0 is replaced by each input. There is no REQUANT opcode.
module npu_vector_stream #(
  parameter bit GATHER = 0
) (

  output logic [2:0] gather_req_o,
  output logic [2:0][31:0] gather_addr_o,
  input logic [2:0] gather_gnt_i,
  gather_valid_i,
  gather_error_i,
  input logic [2:0][31:0] gather_data_i,

  output logic compute_simd_o,
  output logic [4:0] compute_op_o,
  output logic signed [31:0] compute_a_o,
  compute_b_o,
  compute_c_o,
  output logic compute_carry_o,
  input logic compute_carry_i,
  input logic signed [31:0] compute_data_i,

  input logic clk_i,
  rst_ni,
  start_i,
  input logic [31:0] a_i,
  b_i,
  d_i,
  scalar_i,
  input logic [12:0] len_i,
  input logic [7:0] op_i,
  input logic [31:0] program_cfg_i,
  input logic [15:0][31:0] program_i,
  output logic busy_o,
  done_o,
  fault_o,
  req_o,
  we_o,
  output logic [3:0] be_o,
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
    EXEC,
    LOAD_REQ,
    LOAD_WAIT,
    OUTPUT,
    D_REQ,
    D_WAIT
  } state_t;
  state_t state;
  logic [31:0] a_ptr, d_ptr, scalar, write_data, load_addr;
  logic [3:0] write_be, pack_be;
  logic [12:0] remaining;
  logic [7:0] mode;
  logic [4:0] pc, slots, loop_pc;
  logic [1:0] load_dst;
  logic signed [31:0] regs[4];
  logic [31:0] instruction, assembled;
  logic [3:0] assembled_be;
  logic [4:0] operation;
  logic [1:0] dst, src_a, src_b;
  logic signed [31:0] operand_a, operand_b, operand_c, result;
  logic program_mode, packed_mode, last_pc, binary_op, response_error;
  logic carry;
  localparam logic [4:0] issued = 1;
  logic signed [31:0] folded;
  logic [31:0] output_value;

  logic simd_mode;
  assign simd_mode = mode[6];
  assign compute_simd_o = simd_mode && operation != 27;
  npu_multi_read #(
    .GATHER(GATHER)
  ) i_operand_read (
    .clk_i,
    .rst_ni,
    .valid_i (state == A_REQ && !program_mode),
    .ready_o (batch_ready),
    .mask_i  (batch_mask),
    .addr_i  (batch_addresses),
    .valid_o (batch_valid),
    .ready_i (state == A_WAIT),
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
    .gnt_i   (gnt_i && state == A_WAIT),
    .rvalid_i(rvalid_i && state == A_WAIT),
    .error_i,
    .rdata_i
  );
  assign batch_mask = !program_mode && binary_op && !mode[7] ? 3'b011 : 3'b001;
  assign batch_addresses = {32'b0, regs[1], a_ptr};

  function automatic logic [3:0] tail_mask(input logic [12:0] left, input logic simd);
    if (!simd || left >= 4) return 4'hf;
    case (left[1:0])
      0: return 4'h0;
      1: return 4'h1;
      2: return 4'h3;
      default: return 4'h7;
    endcase
  endfunction
  // Operand representation belongs to the issuer, arithmetic to npu_vector.
  function automatic logic signed [31:0] sx32(input logic [31:0] value);
    return value;
  endfunction
  assign program_mode = mode[5];
  assign packed_mode = program_mode && mode[7];
  assign instruction = program_i[pc[3:0]];
  assign operation = program_mode ? instruction[4:0] : mode[4:0];
  assign dst = program_mode ? instruction[6:5] : 0;
  assign src_a = instruction[8:7];
  assign src_b = instruction[10:9];
  assign operand_a = program_mode ? regs[src_a] : batch_data[0];
  assign operand_b=program_mode && operation==27 ? {{12{instruction[31]}},instruction[31:12]}:program_mode ?
    (instruction[11] ? (simd_mode ? {4{instruction[19:12]}} : {{12{instruction[31]}},instruction[31:12]}) : regs[src_b]) :
    (mode[7] ? sx32(
      (simd_mode ? {4{scalar[7:0]}} : scalar)
  ) : batch_data[1]);
  assign operand_c = operation == 29 ? (simd_mode ? {4{scalar[7:0]}} : scalar) : {26'b0,instruction[19:14]};
  assign compute_carry_o = carry;
  assign compute_op_o = operation == 27 ? 5'd1 : operation;
  assign compute_a_o = operand_a;
  assign compute_b_o = operand_b;
  assign compute_c_o = operand_c;
  assign folded = compute_data_i;
  assign result = compute_data_i;
  assign last_pc = pc + issued == slots;
  assign binary_op = operation == 1 || (operation >= 3 && operation <= 12) || (operation >= 16 && operation <= 26);
  assign busy_o = state != IDLE;
  assign req_o = (program_mode && state == A_REQ) || (!program_mode && state == A_WAIT && batch_req) || state == LOAD_REQ || state == D_REQ;
  assign we_o = state == D_REQ;
  assign addr_o = program_mode && state==A_REQ ? a_ptr : state==A_WAIT ? batch_addr : state==LOAD_REQ ? load_addr : (packed_mode ? {d_ptr[31:2],2'b0} : d_ptr);
  assign wdata_o = write_data;
  assign be_o = write_be;
  assign response_error = (state == A_WAIT && !program_mode && batch_valid && |batch_error) || (rvalid_i && error_i && (state==LOAD_WAIT || state==D_WAIT || (program_mode && state==A_WAIT)));
  assign output_value = regs[0];
  always_comb begin
    assembled = write_data;
    assembled[d_ptr[1:0]*8+:8] = output_value[7:0];
    assembled_be = pack_be | (4'b1 << d_ptr[1:0]);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state <= IDLE;
      carry <= 0;
      done_o <= 0;
      fault_o <= 0;
      a_ptr <= 0;
      d_ptr <= 0;
      scalar <= 0;
      remaining <= 0;
      mode <= 0;
      pc <= 0;
      slots <= 0;
      loop_pc <= 0;
      load_dst <= 0;
      load_addr <= 0;
      write_data <= 0;
      write_be <= 0;
      pack_be <= 0;



      for (int i = 0; i < 4; i++) regs[i] <= 0;
    end else begin
      done_o <= 0;
      fault_o <= 0;
      if (response_error) begin
        state <= IDLE;
        fault_o <= 1;
        pack_be <= 0;


      end else
        case (state)
          IDLE:
          if (start_i) begin
            carry <= 0;
            a_ptr <= a_i;
            d_ptr <= d_i;
            scalar <= scalar_i;
            remaining <= len_i;
            mode <= op_i;
            pc <= 0;
            slots <= program_cfg_i[4:0];
            loop_pc <= program_cfg_i[12:8];
            regs[0] <= 0;
            regs[1] <= sx32(b_i);
            regs[2] <= 0;
            regs[3] <= op_i[6] ? {4{scalar_i[7:0]}} : scalar_i;
            pack_be <= 0;
            write_data <= 0;
            write_be <= 4'hf;


            state <= op_i[5] && program_cfg_i[12:8] != 0 ? EXEC : A_REQ;
          end
          A_REQ: if (program_mode ? gnt_i : batch_ready) state <= A_WAIT;
          A_WAIT:
          if (program_mode ? rvalid_i : batch_valid) begin
            if (program_mode) regs[0] <= rdata_i;
            pc <= loop_pc;
            if (program_mode) state <= EXEC;
            else begin
              write_data <= result[31:0];
              write_be <= tail_mask(remaining, simd_mode);
              state <= D_REQ;
            end
          end
          EXEC:
          if (program_mode && operation == 27 && pc < slots) begin
            // Generic LD32 rd,[ra+signed immediate20], for constants or tables.
            load_addr <= compute_data_i;
            load_dst <= dst;
            state <= LOAD_REQ;
          end else if((operation<=24 || operation==26 || operation==29) && (!program_mode || pc<slots) && (!(operation==21 || operation==22) || instruction[19:14]<=32) && (!simd_mode || operation<=15 || operation>=18 && operation<=20 || operation==24 || operation==26 || operation==29)) begin
            if (operation == 16 || operation == 17 || operation == 23) carry <= compute_carry_i;
            regs[dst] <= folded;
            if (!program_mode || last_pc) state <= OUTPUT;
            else begin
              pc <= pc + issued;
              state <= pc + issued == loop_pc ? A_REQ : EXEC;
            end
          end else begin
            state <= IDLE;
            fault_o <= 1;
          end
          LOAD_REQ: if (gnt_i) state <= LOAD_WAIT;
          LOAD_WAIT:
          if (rvalid_i) begin
            regs[load_dst] <= sx32(rdata_i);
            pc <= pc + 1;
            state <= pc + 1 == slots ? OUTPUT : pc + 1 == loop_pc ? A_REQ : EXEC;
          end
          OUTPUT: begin
            if (packed_mode) begin
              write_data <= assembled;
              pack_be <= assembled_be;
              if (d_ptr[1:0] == 3 || remaining == 1) begin
                write_be <= assembled_be;
                state <= D_REQ;
              end else begin
                remaining <= remaining - 1;
                a_ptr <= data_advance(a_ptr, 4);
                d_ptr <= data_advance(d_ptr, 1);
                state <= A_REQ;
              end
            end else begin
              write_data <= regs[0][31:0];
              write_be <= tail_mask(remaining, simd_mode);
              state <= D_REQ;
            end
          end
          D_REQ: if (gnt_i) state <= D_WAIT;
          D_WAIT:
          if (rvalid_i) begin
            write_data <= 0;
            pack_be <= 0;
            if (remaining <= (simd_mode ? 4 : 1)) begin
              state <= IDLE;
              done_o <= 1;
            end else begin
              remaining <= remaining - (simd_mode ? 4 : 1);
              a_ptr <= data_advance(a_ptr, 4);
              if (!program_mode) regs[1] <= data_advance(regs[1], 4);
              d_ptr <= data_advance(d_ptr, packed_mode ? 1 : 4);
              state <= A_REQ;
            end
          end
          default: state <= IDLE;
        endcase
    end
  end
endmodule
