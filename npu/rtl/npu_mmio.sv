module npu_mmio (
  input logic clk_i, rst_ni, req_i, we_i,
  input logic [11:0] addr_i,
  input logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic error_o,
  output logic mat_start_o, vec_start_o,
  output logic [31:0] mat_a_o, mat_b_o, mat_d_o,
  output logic [4:0] mat_m_o, mat_n_o, mat_k_o,
  output logic [31:0] vec_a_o, vec_b_o, vec_d_o,
  output logic [10:0] vec_len_o,
  output logic vec_op_o,
  input logic mat_busy_i, mat_done_i, mat_fault_i,
  input logic vec_busy_i, vec_done_i, vec_fault_i,
  output logic [1:0] irq_o,
  output logic [31:0] test_result_o,
  output logic cpu_release_o,
  output logic [31:0] cpu_boot_addr_o
);
  logic [31:0] ma_q, mb_q, md_q, mm_q, mn_q, mk_q;
  logic [31:0] va_q, vb_q, vd_q, vl_q, vo_q;
  logic [31:0] mat_cycles_q, vec_cycles_q;
  logic mat_done_q, mat_error_q, vec_done_q, vec_error_q;
  logic mat_occupied, vec_occupied, mat_ok, vec_ok, writable, known;
  logic [31:0] a_words, b_words, d_words;
  function automatic logic range_ok(input logic [31:0] base, words);
    return base[31:13] == 19'h40000 && base[1:0] == 0
      && words != 0 && words <= 2048
      && ({19'b0,base[12:0]} + (words << 2)) <= 8192;
  endfunction
  function automatic logic overlaps(input logic [31:0] a, aw, b, bw);
    return {1'b0,a} < ({1'b0,b} + ({1'b0,bw} << 2))
      && {1'b0,b} < ({1'b0,a} + ({1'b0,aw} << 2));
  endfunction
  assign a_words = {27'b0,mm_q[4:0]} * {27'b0,mk_q[4:0]};
  assign b_words = {27'b0,mk_q[4:0]} * {27'b0,mn_q[4:0]};
  assign d_words = {27'b0,mm_q[4:0]} * {27'b0,mn_q[4:0]};
  assign mat_occupied = mat_busy_i || mat_start_o;
  assign vec_occupied = vec_busy_i || vec_start_o;
  assign mat_ok = mm_q >= 1 && mm_q <= 16 && mn_q >= 1 && mn_q <= 16
    && mk_q >= 1 && mk_q <= 16
    && range_ok(ma_q,a_words) && range_ok(mb_q,b_words) && range_ok(md_q,d_words)
    && !overlaps(md_q,d_words,ma_q,a_words) && !overlaps(md_q,d_words,mb_q,b_words);
  assign vec_ok = vl_q >= 1 && vl_q <= 1024 && vo_q <= 1
    && range_ok(va_q,vl_q) && range_ok(vd_q,vl_q)
    && (va_q == vd_q || !overlaps(va_q,vl_q,vd_q,vl_q))
    && (vo_q == 0 || (range_ok(vb_q,vl_q)
      && (vb_q == vd_q || !overlaps(vb_q,vl_q,vd_q,vl_q))));
  assign mat_a_o = ma_q; assign mat_b_o = mb_q; assign mat_d_o = md_q;
  assign mat_m_o = mm_q[4:0]; assign mat_n_o = mn_q[4:0]; assign mat_k_o = mk_q[4:0];
  assign vec_a_o = va_q; assign vec_b_o = vb_q; assign vec_d_o = vd_q;
  assign vec_len_o = vl_q[10:0]; assign vec_op_o = vo_q[0];
  assign irq_o = {vec_done_q, mat_done_q};
  always_comb begin
    rdata_o = 0; known = 1; writable = 1;
    case (addr_i)
      12'h000: begin rdata_o = 32'h4e505531; writable = 0; end // "NPU1"
      12'h004: rdata_o = test_result_o;
      12'h008: rdata_o = {31'b0,cpu_release_o};
      12'h00c: rdata_o = cpu_boot_addr_o;
      12'h100: rdata_o = 0;
      12'h104: begin rdata_o = {29'b0,mat_error_q,mat_done_q,mat_occupied}; writable = 0; end
      12'h108: rdata_o = ma_q;
      12'h10c: rdata_o = mb_q;
      12'h110: rdata_o = md_q;
      12'h114: rdata_o = mm_q;
      12'h118: rdata_o = mn_q;
      12'h11c: rdata_o = mk_q;
      12'h120: begin rdata_o = mat_cycles_q; writable = 0; end
      12'h200: rdata_o = 0;
      12'h204: begin rdata_o = {29'b0,vec_error_q,vec_done_q,vec_occupied}; writable = 0; end
      12'h208: rdata_o = va_q;
      12'h20c: rdata_o = vd_q;
      12'h210: rdata_o = vl_q;
      12'h214: rdata_o = vo_q;
      12'h218: rdata_o = vb_q;
      12'h220: begin rdata_o = vec_cycles_q; writable = 0; end
      default: begin rdata_o = 32'hdeadbeef; known = 0; writable = 0; end
    endcase
    error_o = !known || (we_i && !writable)
      || (we_i && addr_i == 12'h00c && (cpu_release_o
        || wdata_i[31:13] != 19'h40000 || wdata_i[1:0] != 0))
      || (we_i && addr_i >= 12'h108 && addr_i <= 12'h11c && mat_occupied)
      || (we_i && addr_i >= 12'h208 && addr_i <= 12'h218 && vec_occupied);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ma_q <= 0; mb_q <= 0; md_q <= 0; mm_q <= 0; mn_q <= 0; mk_q <= 0;
      va_q <= 0; vb_q <= 0; vd_q <= 0; vl_q <= 0; vo_q <= 0;
      mat_start_o <= 0; vec_start_o <= 0;
      mat_done_q <= 0; mat_error_q <= 0; vec_done_q <= 0; vec_error_q <= 0;
      mat_cycles_q <= 0; vec_cycles_q <= 0; test_result_o <= 0;
      cpu_release_o <= 0; cpu_boot_addr_o <= 32'h80000080;
    end else begin
      mat_start_o <= 0; vec_start_o <= 0;
      if (mat_busy_i) mat_cycles_q <= mat_cycles_q + 1'b1;
      if (vec_busy_i) vec_cycles_q <= vec_cycles_q + 1'b1;
      if (mat_done_i) mat_done_q <= 1;
      if (vec_done_i) vec_done_q <= 1;
      if (mat_fault_i) mat_error_q <= 1;
      if (vec_fault_i) vec_error_q <= 1;
      if (req_i && we_i) begin
        if (addr_i >= 12'h108 && addr_i <= 12'h11c && mat_occupied) mat_error_q <= 1;
        if (addr_i >= 12'h208 && addr_i <= 12'h218 && vec_occupied) vec_error_q <= 1;
        if (!error_o) case (addr_i)
          12'h004: test_result_o <= wdata_i;
          12'h008: cpu_release_o <= wdata_i[0];
          12'h00c: cpu_boot_addr_o <= wdata_i;
          12'h100: begin
            if (mat_occupied) begin
              if (wdata_i[1:0] != 0) mat_error_q <= 1;
            end else begin
              if (wdata_i[1]) begin mat_done_q <= 0; mat_error_q <= 0; end
              if (wdata_i[0]) begin
                mat_done_q <= 0; mat_error_q <= !mat_ok;
                if (mat_ok) begin mat_start_o <= 1; mat_cycles_q <= 0; end
              end
            end
          end
          12'h108: ma_q <= wdata_i;
          12'h10c: mb_q <= wdata_i;
          12'h110: md_q <= wdata_i;
          12'h114: mm_q <= wdata_i;
          12'h118: mn_q <= wdata_i;
          12'h11c: mk_q <= wdata_i;
          12'h200: begin
            if (vec_occupied) begin
              if (wdata_i[1:0] != 0) vec_error_q <= 1;
            end else begin
              if (wdata_i[1]) begin vec_done_q <= 0; vec_error_q <= 0; end
              if (wdata_i[0]) begin
                vec_done_q <= 0; vec_error_q <= !vec_ok;
                if (vec_ok) begin vec_start_o <= 1; vec_cycles_q <= 0; end
              end
            end
          end
          12'h208: va_q <= wdata_i;
          12'h20c: vd_q <= wdata_i;
          12'h210: vl_q <= wdata_i;
          12'h214: vo_q <= wdata_i;
          12'h218: vb_q <= wdata_i;
          default: ;
        endcase
      end
    end
  end
endmodule
