`ifndef NPU_MATRIX_QUEUE_DEPTH
`define NPU_MATRIX_QUEUE_DEPTH 8
`endif
`ifndef NPU_VECTOR_QUEUE_DEPTH
`define NPU_VECTOR_QUEUE_DEPTH 8
`endif
// Matrix/vector control: mutable CSR shadows -> validated FIFO snapshots ->
// stable active ports. CNN has its own control module/CSR page; former DMA pages are reserved.
module npu_mmio #(
  parameter int MATRIX_QUEUE_DEPTH = `NPU_MATRIX_QUEUE_DEPTH,
  parameter int VECTOR_QUEUE_DEPTH = `NPU_VECTOR_QUEUE_DEPTH
) (
  input logic clk_i,
  rst_ni,
  req_i,
  we_i,
  input logic [1:0][31:0] cache_hits_i,
  cache_misses_i,
  bank_accepts_i,
  input logic [11:0] addr_i,
  input logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic error_o,
  output logic mat_start_o,
  vec_start_o,
  mat_pending_o,
  output logic [31:0] mat_a_o,
  mat_b_o,
  mat_d_o,
  output logic [4:0] mat_m_o,
  mat_n_o,
  output logic [8:0] mat_k_o,
  output logic [31:0] vec_a_o,
  vec_b_o,
  vec_d_o,
  output logic [12:0] vec_len_o,
  output logic [8:0] vec_op_o,
  output logic [31:0] vec_scalar_o,
  output logic [31:0] vec_program_cfg_o,
  output logic [15:0][31:0] vec_program_o,
  output logic [15:0] mat_lda_o,
  mat_ldb_o,
  output logic [4:0] mat_flags_o,
  output logic mat_precision_o,
  output logic [1:0] mat_element_log2_o,
  input logic [31:0] mat_observe_i,
  vec_observe_i,
  input logic mat_busy_i,
  mat_done_i,
  mat_fault_i,
  mat_blocked_i,
  input logic vec_busy_i,
  vec_done_i,
  vec_fault_i,
  output logic [1:0] irq_o,
  output logic [31:0] test_result_o,
  output logic cpu_release_o,
  output logic [31:0] cpu_boot_addr_o
);
  import npu_addr_pkg::*;
  logic [31:0] ma_q, mb_q, md_q, mm_q, mn_q, mk_q, va_q, vb_q, vd_q, vl_q, vo_q, mf_q, vs_q;
  logic [31:0]
      mat_cycles_q, vec_cycles_q, mat_completed, vec_completed, mat_submitted, vec_submitted;
  logic [31:0] mat_started, vec_started, mat_ticket, vec_ticket, mat_faults, vec_faults;
  logic mat_done_q, mat_error_q, vec_done_q, vec_error_q, mat_ok, vec_ok;
  logic mat_occupied, vec_occupied, writable, known, mpush, vpush, mpop, vpop;
  logic [12:0] mla_q, mlb_q;
  logic [31:0] mp_q, me_q;
  logic [1:0] element_log2;
  logic [31:0] a_words, b_words, d_words;
  logic [12:0] lda, ldb;
  logic [20:0] a_span, b_span;
  logic vec_direct_ok, vec_program_ok;
  logic [31:0] vec_words;
  assign vec_words = vo_q[6] ? (vl_q + 3) >> 2 : vl_q;
  typedef struct packed {
    logic [14:0] a, b, d;
    logic [4:0] m, n;
    logic [8:0] k;
    logic [2:0] flags;
    logic precision;
    logic [1:0] element_log2;
    logic [12:0] lda, ldb;
  } mat_desc_t;
  typedef struct packed {
    logic [14:0] a, b, d;
    logic [12:0] len;
    logic [8:0] op;
    logic [31:0] scalar;
  } vec_desc_t;
  localparam int MPW = MATRIX_QUEUE_DEPTH > 1 ? $clog2(MATRIX_QUEUE_DEPTH) : 1;
  localparam int VPW = VECTOR_QUEUE_DEPTH > 1 ? $clog2(VECTOR_QUEUE_DEPTH) : 1;
  mat_desc_t mq[MATRIX_QUEUE_DEPTH];
  vec_desc_t vq[VECTOR_QUEUE_DEPTH];
  logic [MPW-1:0] mh, mt;
  logic [VPW-1:0] vh, vt;
  logic [$clog2(MATRIX_QUEUE_DEPTH+1)-1:0] mc;
  logic [$clog2(VECTOR_QUEUE_DEPTH+1)-1:0] vc;
  function automatic logic [MPW-1:0] mnext(input logic [MPW-1:0] p);
    return p == MATRIX_QUEUE_DEPTH - 1 ? '0 : p + 1'b1;
  endfunction
  function automatic logic [VPW-1:0] vnext(input logic [VPW-1:0] p);
    return p == VECTOR_QUEUE_DEPTH - 1 ? '0 : p + 1'b1;
  endfunction
  function automatic logic range_ok(input logic [31:0] base, words);
    return base[1:0] == 0 && words != 0 &&
        (is_stream_address(base) || (words <= 4096 && data_range_ok(base, words << 2)));
  endfunction
  function automatic logic overlaps(input logic [31:0] a, aw, b, bw);
    // FIFO endpoints are channels, not linear byte ranges. Their synthetic
    // tensor span must not alias the next channel when K grows.
    if (is_stream_address(a) || is_stream_address(b))
      return is_stream_address(a) && is_stream_address(b) && a[9:8] == b[9:8];
    // Callers also validate both addresses and lengths (<=4096 words).
    // All data targets share the same upper 17 address bits. Keep the carry
    // for FIFO spans extending beyond the aperture; do not wrap the endpoint.
    return {1'b0,a[14:0]} < ({1'b0,b[14:0]} + {1'b0,bw[12:0],2'b0})
      && {1'b0,b[14:0]} < ({1'b0,a[14:0]} + {1'b0,aw[12:0],2'b0});
  endfunction
  assign lda = mla_q != 0 ? mla_q : mf_q[0] ? {8'b0, mm_q[4:0]} : {4'b0, mk_q[8:0]};
  assign ldb = mlb_q != 0 ? mlb_q : mf_q[1] ? {4'b0, mk_q[8:0]} : {8'b0, mn_q[4:0]};
  assign a_span=21'(8'((mf_q[0] ? mk_q[8:0]:mm_q[4:0])-1))*21'(lda)+21'(mf_q[0] ? mm_q[4:0] : mk_q[8:0]);
  assign b_span=21'(8'((mf_q[1] ? mn_q[4:0]:mk_q[8:0])-1))*21'(ldb)+21'(mf_q[1] ? mk_q[8:0] : mn_q[4:0]);
  assign element_log2 = me_q == 1 ? 0 : me_q == 2 ? 1 : 2;
  assign a_words = ((32'(a_span) << element_log2) + 3) >> 2;
  assign b_words = ((32'(b_span) << element_log2) + 3) >> 2;
  assign d_words = {27'b0, mm_q[4:0]} * {27'b0, mn_q[4:0]};
  assign mat_ok=mm_q>=1 && mm_q<=16 && mn_q>=1 && mn_q<=16 && mf_q<=7 && mp_q<=1 &&
    (me_q==1 || me_q==2 || me_q==4) && (!mp_q || me_q>=2) &&
    mk_q<=256 && (mk_q>=1 || mf_q[2]) && range_ok(
      md_q, d_words
  ) && (mk_q == 0 || (lda >= (mf_q[0] ? mm_q : mk_q) && ldb >= (mf_q[1] ? mk_q : mn_q) && range_ok(
      ma_q, a_words
  ) && range_ok(
      mb_q, b_words
  ) && !overlaps(
      md_q, d_words, ma_q, a_words
  ) && !overlaps(
      md_q, d_words, mb_q, b_words
  )));
  // Direct 32-bit operations; wide VPG1 operations are no longer accepted.
  // Former fused REQUANT encodings are deliberately rejected.
  assign vec_direct_ok = vl_q>=1 && vl_q<=4096 && (vo_q&32'hffffff20)==0
    && (vo_q[4:0]<=15 || (vo_q[4:0]>=18 && vo_q[4:0]<=20) || vo_q[4:0]==24 || vo_q[4:0]==26)
    && range_ok(
      va_q, vec_words
  ) && range_ok(
      vd_q, vec_words
  ) && (va_q == vd_q || !overlaps(
      va_q, vec_words, vd_q, vec_words
  )) && (vo_q[7] || vo_q[4:0] == 0 || vo_q[4:0] == 2 || (vo_q[4:0] >= 13 && vo_q[4:0] <= 15) ||
         (range_ok(
      vb_q, vec_words
  ) && (vb_q == vd_q || !overlaps(
      vb_q, vec_words, vd_q, vec_words
  ))));
  // Program words are live shared state. Software owns update timing; each
  // job snapshots count/loop at start, and reads program words during execution.
  assign vec_program_ok = (vo_q==32'h20 || vo_q==32'h120 || vo_q==32'h60)
    && vl_q>=1 && vl_q<=4096 && vec_program_cfg_o[4:0]>=1 && vec_program_cfg_o[4:0]<=16
    && vec_program_cfg_o[12:8]<vec_program_cfg_o[4:0]
    && (range_ok(
      va_q, vec_words
  )) && (vo_q[8] ? data_range_ok(
      vd_q, vec_words
  ) : range_ok(
      vd_q, vec_words
  )) && (vec_program_cfg_o[12:8] == 0 || range_ok(
      vb_q, 1
  )) && ((vo_q[8] ? !({1'b0, vd_q} < {1'b0, va_q} + ({1'b0, vl_q} << 2) &&
                      {1'b0, va_q} < {1'b0, vd_q} + vl_q) : va_q == vd_q || !overlaps(
      va_q, vec_words, vd_q, vec_words
  )));
  assign vec_ok = vec_direct_ok || vec_program_ok;


  assign mat_pending_o = mc != 0 || mat_start_o;
  assign mat_occupied = mat_busy_i || mat_start_o || mc != 0;
  assign vec_occupied = vec_busy_i || vec_start_o || vc != 0;
  // The registered start pulse is part of occupancy: busy_i only rises on the
  // following edge. Without this guard one idle engine could pop two tasks.
  assign mpop = mc != 0 && !mat_busy_i && !mat_blocked_i && !mat_start_o;
  assign vpop = vc != 0 && !vec_busy_i && !vec_start_o;
  assign mpush = req_i && we_i && addr_i == 12'h100 && wdata_i[0] && !error_o && mat_ok;
  assign vpush = req_i && we_i && addr_i == 12'h200 && wdata_i[0] && !error_o && vec_ok;
  assign irq_o = {vec_done_q || vec_error_q, mat_done_q || mat_error_q};
  always_comb begin
    rdata_o = 0;
    known = 1;
    writable = 1;
    case (addr_i)
      12'h000: begin
        rdata_o = 32'h4e505532;
        writable = 0;
      end
      12'h004: rdata_o = test_result_o;
      12'h008: rdata_o = {31'b0, cpu_release_o};
      12'h00c: rdata_o = cpu_boot_addr_o;
      12'h020: begin
        rdata_o = cache_hits_i[0];
        writable = 0;
      end
      12'h024: begin
        rdata_o = cache_hits_i[1];
        writable = 0;
      end
      12'h028: begin
        rdata_o = cache_misses_i[0];
        writable = 0;
      end
      12'h02c: begin
        rdata_o = cache_misses_i[1];
        writable = 0;
      end
      12'h030: begin
        rdata_o = bank_accepts_i[0];
        writable = 0;
      end
      12'h034: begin
        rdata_o = bank_accepts_i[1];
        writable = 0;
      end
      12'h038: begin
        rdata_o = {8'd2, 8'd32, 16'd16384};
        writable = 0;
      end
      12'h03c: begin
        rdata_o = {16'd2, 16'd0};  // Two SRAM banks, no transparent cache
        writable = 0;
      end
      12'h068: begin
        rdata_o = 32'h00030408;  // flags[17:16]: direct/program; 4 lanes x INT8
        writable = 0;
      end
      12'h040: begin
        rdata_o = 32'h00020002;
        writable = 0;
      end
      12'h044: begin
        rdata_o = 32'h00000007;
        writable = 0;
      end
      12'h048: begin
        rdata_o = 32'h051cffff;
        writable = 0;
      end
      12'h04c: begin
        rdata_o = 32'h0000000f;
        writable = 0;
      end
      12'h050: begin
        rdata_o = {16'd2, 16'(RF_BANK_WORDS)};
        writable = 0;
      end
      12'h05c: begin
        rdata_o = 32'h00030820;  // 3 gather lanes, 8 physical RF banks, 32 bits/lane
        writable = 0;
      end
      12'h058: begin
        rdata_o = 32'h56504733;  // VPG3: ordered fields and independent output format
        writable = 0;
      end
      12'h054: begin
        rdata_o = RF_BASE;
        writable = 0;
      end
      12'h060: begin
        rdata_o = {16'd4, 16'(STREAM_FIFO_DEPTH)};
        writable = 0;
      end
      12'h064: begin
        rdata_o = STREAM_BASE;
        writable = 0;
      end
      12'h100, 12'h200: rdata_o = 0;
      12'h104: begin
        rdata_o = {29'b0, mat_error_q, mat_done_q, mat_occupied};
        writable = 0;
      end
      12'h108: rdata_o = ma_q;
      12'h10c: rdata_o = mb_q;
      12'h110: rdata_o = md_q;
      12'h114: rdata_o = mm_q;
      12'h118: rdata_o = mn_q;
      12'h11c: rdata_o = mk_q;
      12'h120: begin
        rdata_o = mat_cycles_q;
        writable = 0;
      end
      12'h124: begin
        rdata_o = (MATRIX_QUEUE_DEPTH << 16) | 32'(mc);
        writable = 0;
      end
      12'h128: begin
        rdata_o = mat_completed;
        writable = 0;
      end
      12'h130: rdata_o = mf_q;
      12'h134: rdata_o = {19'b0, mla_q};
      12'h138: rdata_o = {19'b0, mlb_q};
      12'h13c: rdata_o = mp_q;
      12'h140: rdata_o = me_q;
      12'h084: begin
        rdata_o = 32'h0002007f;
        writable = 0;
      end
      12'h144: begin
        rdata_o = mat_started;
        writable = 0;
      end
      12'h148: begin
        rdata_o = mat_ticket;
        writable = 0;
      end
      12'h14c: begin
        rdata_o = mat_faults;
        writable = 0;
      end
      12'h150: begin
        rdata_o = mat_observe_i;
        writable = 0;
      end
      12'h154: begin
        rdata_o = {
          26'b0, mat_blocked_i, mat_fault_i, mat_done_i, (mc != 0), mat_start_o, mat_busy_i
        };
        writable = 0;
      end
      12'h238: begin
        rdata_o = vec_started;
        writable = 0;
      end
      12'h23c: begin
        rdata_o = vec_ticket;
        writable = 0;
      end
      12'h280: begin
        rdata_o = vec_faults;
        writable = 0;
      end
      12'h284: begin
        rdata_o = vec_observe_i;
        writable = 0;
      end
      12'h288: begin
        rdata_o = {27'b0, vec_fault_i, vec_done_i, (vc != 0), vec_start_o, vec_busy_i};
        writable = 0;
      end
      12'h080: begin
        rdata_o = 32'hf;  // Runtime config writes: CNN, Matrix, Vector program, quant.
        writable = 0;
      end
      12'h074: begin
        rdata_o = {16'd256, 8'd16, 8'd16};  // K, N, M
        writable = 0;
      end
      12'h078: begin
        rdata_o = 4096;  // Elements, independent of vector precision.
        writable = 0;
      end
      12'h07c: begin
        rdata_o = 256;  // CNN input channels.
        writable = 0;
      end
      12'h070: begin
        rdata_o = IRQ_MASK;
        writable = 0;
      end
      12'h06c: begin
        rdata_o = 32'h00040404;
        writable = 0;
      end
      12'h12c: begin
        rdata_o = mat_submitted;
        writable = 0;
      end
      12'h204: begin
        rdata_o = {29'b0, vec_error_q, vec_done_q, vec_occupied};
        writable = 0;
      end
      12'h208: rdata_o = va_q;
      12'h20c: rdata_o = vd_q;
      12'h210: rdata_o = vl_q;
      12'h214: rdata_o = vo_q;
      12'h218: rdata_o = vb_q;
      12'h220: begin
        rdata_o = vec_cycles_q;
        writable = 0;
      end
      12'h224: begin
        rdata_o = (VECTOR_QUEUE_DEPTH << 16) | 32'(vc);
        writable = 0;
      end
      12'h228: begin
        rdata_o = vec_completed;
        writable = 0;
      end
      12'h230: rdata_o = vs_q;
      12'h234: rdata_o = vec_program_cfg_o;
      12'h22c: begin
        rdata_o = vec_submitted;
        writable = 0;
      end
      default: begin
        rdata_o = 32'hdeadbeef;
        known = 0;
        writable = 0;
        if (addr_i >= 12'h240 && addr_i <= 12'h27c && addr_i[1:0] == 0) begin
          rdata_o = vec_program_o[addr_i[5:2]];
          known = 1;
          writable = 1;
        end
      end
    endcase
    error_o=(we_i && (addr_i==12'h134 || addr_i==12'h138) && (wdata_i>4096)) || !known || (we_i&&!writable) || (we_i && addr_i==12'h00c &&
      (cpu_release_o || wdata_i[31:14]!=18'h20000 || wdata_i[1:0]!=0)) ||
      (we_i && addr_i==12'h100 && wdata_i[0] && mc==MATRIX_QUEUE_DEPTH && !mpop) ||
      (we_i && addr_i==12'h200 && wdata_i[0] && vc==VECTOR_QUEUE_DEPTH && !vpop);
  end
  // Occupancy reset invalidates payload. No read occurs before a fresh push.
  always_ff @(posedge clk_i) begin
    if (mpush)
      mq[mt] <= {
        ma_q[14:0],
        mb_q[14:0],
        md_q[14:0],
        mm_q[4:0],
        mn_q[4:0],
        mk_q[8:0],
        mf_q[2:0],
        mp_q[0],
        element_log2,
        lda[12:0],
        ldb[12:0]
      };
    if (vpush) vq[vt] <= {va_q[14:0], vb_q[14:0], vd_q[14:0], vl_q[12:0], vo_q[8:0], vs_q};
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ma_q <= 0;
      mb_q <= 0;
      md_q <= 0;
      mm_q <= 0;
      mn_q <= 0;
      mk_q <= 0;
      va_q <= 0;
      vb_q <= 0;
      vd_q <= 0;
      vl_q <= 0;
      vo_q <= 0;
      mf_q <= 0;
      mat_lda_o <= 0;
      mla_q <= 0;
      mlb_q <= 0;
      mp_q <= 0;
      me_q <= 4;
      mat_precision_o <= 0;
      mat_element_log2_o <= 2;
      mat_ldb_o <= 0;
      vs_q <= 0;
      vec_program_cfg_o <= 0;
      vec_program_o <= 0;
      mat_a_o <= 0;
      mat_b_o <= 0;
      mat_d_o <= 0;
      mat_m_o <= 0;
      mat_n_o <= 0;
      mat_k_o <= 0;
      vec_a_o <= 0;
      vec_b_o <= 0;
      vec_d_o <= 0;
      vec_len_o <= 0;
      vec_op_o <= 0;
      vec_scalar_o <= 0;
      mat_flags_o <= 0;
      mh <= 0;
      mt <= 0;
      vh <= 0;
      vt <= 0;
      mc <= 0;
      vc <= 0;
      mat_start_o <= 0;
      vec_start_o <= 0;
      mat_done_q <= 0;
      vec_done_q <= 0;
      mat_error_q <= 0;
      vec_error_q <= 0;
      mat_started <= 0;
      vec_started <= 0;
      mat_ticket <= 0;
      vec_ticket <= 0;
      mat_faults <= 0;
      vec_faults <= 0;
      mat_completed <= 0;
      vec_completed <= 0;
      mat_submitted <= 0;
      vec_submitted <= 0;
      mat_cycles_q <= 0;
      vec_cycles_q <= 0;
      test_result_o <= 0;
      cpu_release_o <= 0;
      cpu_boot_addr_o <= 32'h80000080;
    end else begin
      mat_start_o <= 0;
      vec_start_o <= 0;
      if (mat_busy_i) mat_cycles_q <= mat_cycles_q + 1;
      if (vec_busy_i) vec_cycles_q <= vec_cycles_q + 1;
      // Count the actual engine latch edge, one cycle after FIFO pop.
      if (mat_start_o) begin
        mat_started <= mat_started + 1;
        mat_ticket <= mat_submitted - 32'(mc);
      end
      if (vec_start_o) begin
        vec_started <= vec_started + 1;
        vec_ticket <= vec_submitted - 32'(vc);
      end
      if (mat_fault_i) mat_faults <= mat_faults + 1;
      if (vec_fault_i) vec_faults <= vec_faults + 1;
      if (mat_done_i && !mat_fault_i) mat_completed <= mat_completed + 1;
      if (vec_done_i && !vec_fault_i) vec_completed <= vec_completed + 1;
      case ({
        mpush, mpop
      })
        2'b10: mc <= mc + 1;
        2'b01: mc <= mc - 1;
        default: ;
      endcase
      case ({
        vpush, vpop
      })
        2'b10: vc <= vc + 1;
        2'b01: vc <= vc - 1;
        default: ;
      endcase
      // Push/pop may occur together, including when full. Occupancy changes
      // only for one-sided transfers; queue data and active ports are separate.
      if (mpush) begin
        if (!mat_occupied) mat_error_q <= 0;
        mt <= mnext(mt);
        mat_submitted <= mat_submitted + 1;
        mat_done_q <= 0;
      end
      if (vpush) begin
        if (!vec_occupied) vec_error_q <= 0;
        vt <= vnext(vt);
        vec_submitted <= vec_submitted + 1;
        vec_done_q <= 0;
      end
      if (mpop) begin
        mat_a_o <= {17'h10000, mq[mh].a};
        mat_b_o <= {17'h10000, mq[mh].b};
        mat_d_o <= {17'h10000, mq[mh].d};
        mat_m_o <= mq[mh].m;
        mat_n_o <= mq[mh].n;
        mat_k_o <= mq[mh].k;
        mat_flags_o <= {2'b0, mq[mh].flags};
        mat_precision_o <= mq[mh].precision;
        mat_element_log2_o <= mq[mh].element_log2;
        mat_lda_o <= {3'b0, mq[mh].lda};
        mat_ldb_o <= {3'b0, mq[mh].ldb};
        mh <= mnext(mh);
        mat_start_o <= 1;
      end
      if (vpop) begin
        vec_a_o <= {17'h10000, vq[vh].a};
        vec_b_o <= {17'h10000, vq[vh].b};
        vec_d_o <= {17'h10000, vq[vh].d};
        vec_len_o <= vq[vh].len;
        vec_op_o <= vq[vh].op;
        vec_scalar_o <= vq[vh].scalar;
        vh <= vnext(vh);
        vec_start_o <= 1;
      end
      if (req_i && we_i) begin
        if (error_o && addr_i == 12'h100) mat_error_q <= 1;
        if (error_o && addr_i == 12'h200) vec_error_q <= 1;
        if (!error_o)
          case (addr_i)
            12'h004: test_result_o <= wdata_i;
            12'h008: cpu_release_o <= wdata_i[0];
            12'h00c: cpu_boot_addr_o <= wdata_i;
            12'h100: begin
              // bit3 acknowledges done without touching work or sticky errors.
              if (wdata_i[3]) mat_done_q <= 0;
              if (wdata_i[1]) begin
                if (mat_occupied) mat_error_q <= 1;
                else begin
                  mat_done_q <= 0;
                  mat_error_q <= 0;
                end
              end
              if (wdata_i[0] && !mat_ok) begin
                mat_error_q <= 1;
                mat_done_q <= 0;
              end
            end
            12'h200: begin
              if (wdata_i[3]) vec_done_q <= 0;
              if (wdata_i[1]) begin
                if (vec_occupied) vec_error_q <= 1;
                else begin
                  vec_done_q <= 0;
                  vec_error_q <= 0;
                end
              end
              if (wdata_i[0] && !vec_ok) begin
                vec_error_q <= 1;
                vec_done_q <= 0;
              end
            end
            12'h108: ma_q <= wdata_i;
            12'h10c: mb_q <= wdata_i;
            12'h110: md_q <= wdata_i;
            12'h114: mm_q <= wdata_i;
            12'h118: mn_q <= wdata_i;
            12'h11c: mk_q <= wdata_i;
            12'h208: va_q <= wdata_i;
            12'h20c: vd_q <= wdata_i;
            12'h210: vl_q <= wdata_i;
            12'h214: vo_q <= wdata_i;
            12'h218: vb_q <= wdata_i;
            12'h130: mf_q <= wdata_i;
            12'h134: mla_q <= wdata_i[12:0];
            12'h13c: mp_q <= wdata_i;
            12'h140: me_q <= wdata_i;
            12'h138: mlb_q <= wdata_i[12:0];
            12'h230: vs_q <= wdata_i;
            12'h234: vec_program_cfg_o <= wdata_i;
            default:
            if (addr_i >= 12'h240 && addr_i <= 12'h27c && addr_i[1:0] == 0)
              vec_program_o[addr_i[5:2]] <= wdata_i;
          endcase
      end
      // Fresh events dominate simultaneous software acknowledgement/submission.
      // Errors wake WFI even when no successful task completes.
      if (mat_done_i && !mat_fault_i) mat_done_q <= 1;
      if (vec_done_i && !vec_fault_i) vec_done_q <= 1;
      if (mat_fault_i) mat_error_q <= 1;
      if (vec_fault_i) vec_error_q <= 1;
    end
  end
endmodule
