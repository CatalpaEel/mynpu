`ifndef NPU_PARALLEL_UNITS
`define NPU_PARALLEL_UNITS 1
`endif
module npu_core #(
  parameter bit PARALLEL_UNITS = `NPU_PARALLEL_UNITS
) (
  input logic clk_i,
  rst_ni,
  cpu_run_i,
  input logic tck_i,
  tms_i,
  td_i,
  output logic td_o,
  cpu_debug_halted_o,
  system_rst_no,
  input logic host_req_i,
  host_we_i,
  input logic [3:0] host_be_i,
  input logic [31:0] host_addr_i,
  host_wdata_i,
  output logic host_gnt_o,
  host_rvalid_o,
  host_error_o,
  output logic [31:0] host_rdata_o,
  output logic [4:0] irq_o,
  output logic cpu_test_done_o,
  cpu_test_pass_o,
  output logic [1:0] sram_req_o,
  output logic [1:0][3:0] sram_wen_o,
  output logic [1:0][10:0] sram_addr_o,
  output logic [1:0][31:0] sram_wdata_o,
  input logic [1:0][31:0] sram_rdata_i
);
  logic is_quant_mmio, quant_error, cnn_quant_final, cnn_filtered_final;
  logic [31:0] quant_rdata, matrix_observe, vector_observe;
  logic [1:0][3:0] quant_written, quant_write_fault, quant_cancelled;
  logic [1:0] quant_enable, quant_pack, quant_valid, quant_ready, quant_out_valid, quant_out_ready;
  logic [1:0][31:0] quant_dst, quant_in_data, quant_out_data;
  logic cnn_filtered_valid, cnn_filtered_ready, matrix_filtered_valid, matrix_filtered_ready;
  logic [31:0] cnn_filtered_data, matrix_filtered_data;
  logic [3:0] matrix_be;
  logic [5:0] req, we, gnt, rvalid, bus_error;
  logic debug_req, dm_req, dm_we;
  logic [3:0] dm_be;
  logic [31:0] dm_addr, dm_wdata, dm_rdata, boot_rdata;
  logic [2:0] cpu_reset_count;
  logic boot_wait;
  logic host_bus_req, host_bus_we;
  logic [3:0] host_bus_be;
  logic [31:0] host_bus_addr, host_bus_wdata;
  logic [1:0][31:0] cache_hits, cache_misses, bank_accepts;
  logic [5:0][3:0] be;
  logic [5:0][31:0] addr, wdata, rdata;
  logic [1:0] mem_req;
  logic [1:0][3:0] mem_wen;
  logic [1:0][10:0] mem_addr;
  logic [1:0][31:0] mem_wdata, mem_rdata;
  logic mmio_req, mmio_we, mmio_error;
  logic [11:0] mmio_addr;
  logic [31:0] mmio_wdata, mmio_rdata, test_result, control_rdata;
  logic removed_dma_page, control_error, cpu_release, cpu_rst_n;
  logic [31:0] cpu_boot_addr;
  logic [1:0] control_irq;
  logic cnn_irq;
  logic cnn_busy, cnn_done, cnn_error, cnn_req, cnn_we, mat_req, mat_we;
  logic [3:0] cnn_be, cnn_rf_sink_be;
  logic [31:0] cnn_rdata, cnn_addr, cnn_wdata, mat_addr, mat_wdata;
  logic [2:0] cnn_gather_req, cnn_gather_gnt, cnn_gather_valid, cnn_gather_error;
  logic [2:0][31:0] cnn_gather_addr, cnn_gather_data;
  logic cnn_rf_sink_req, cnn_rf_sink_gnt, cnn_rf_sink_rvalid, cnn_rf_sink_error;
  logic [31:0] cnn_rf_sink_addr, cnn_rf_sink_wdata;
  logic [8:0] all_gather_req, all_gather_gnt, all_gather_valid, all_gather_error;
  logic [8:0][31:0] all_gather_addr, all_gather_data;
  assign all_gather_req[2:0] = cnn_gather_req;
  assign all_gather_addr[2:0] = cnn_gather_addr;
  assign cnn_gather_gnt = all_gather_gnt[2:0];
  assign cnn_gather_valid = all_gather_valid[2:0];
  assign cnn_gather_error = all_gather_error[2:0];
  assign cnn_gather_data = all_gather_data[2:0];
  logic is_cnn_mmio;
  logic
      mat_start,
      vec_start,
      mat_pending,
      mat_busy,
      mat_done,
      mat_fault,
      vec_busy,
      vec_done,
      vec_fault;
  logic [31:0] ma, mb, md, va, vb, vd;
  logic [15:0] matrix_lda, matrix_ldb;
  logic [4:0] mm, mn;
  logic [8:0] mk;
  logic [12:0] vl;
  logic [8:0] vo;
  logic [31:0] vs, vector_program_cfg;
  logic [15:0][31:0] vector_program;
  logic [4:0] mf;
  logic matrix_precision;
  logic [1:0] matrix_element_log2;
  npu_jtag_debug i_debug (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .tck_i             (tck_i),
    .tms_i             (tms_i),
    .td_i              (td_i),
    .td_o              (td_o),
    .system_rst_no     (system_rst_no),
    .debug_req_o       (debug_req),
    .hart_unavailable_i(!cpu_rst_n),
    .host_req_i        (host_req_i),
    .host_we_i         (host_we_i),
    .host_be_i         (host_be_i),
    .host_addr_i       (host_addr_i),
    .host_wdata_i      (host_wdata_i),
    .host_gnt_o        (host_gnt_o),
    .host_rvalid_o     (host_rvalid_o),
    .host_error_o      (host_error_o),
    .host_rdata_o      (host_rdata_o),
    .bus_req_o         (host_bus_req),
    .bus_we_o          (host_bus_we),
    .bus_be_o          (host_bus_be),
    .bus_addr_o        (host_bus_addr),
    .bus_wdata_o       (host_bus_wdata),
    .bus_gnt_i         (gnt[3]),
    .bus_rvalid_i      (rvalid[3]),
    .bus_error_i       (bus_error[3]),
    .bus_rdata_i       (rdata[3]),
    .dm_req_i          (dm_req),
    .dm_we_i           (dm_we),
    .dm_be_i           (dm_be),
    .dm_addr_i         (dm_addr),
    .dm_wdata_i        (dm_wdata),
    .dm_rdata_o        (dm_rdata)
  );
  npu_debug_boot i_boot (
    .word_i(dm_addr[5:2]),
    .data_o(boot_rdata)
  );
  assign req[3] = host_bus_req;
  assign we[3] = host_bus_we;
  assign be[3] = host_bus_be;
  assign addr[3] = host_bus_addr;
  assign wdata[3] = host_bus_wdata;
  // Independent masters: 0 CPU data, 1 CNN, 2 Vector, 3 Host/JTAG,
  // 4 CPU fetch, 5 Matrix. FIFO endpoints support concurrent producer/consumer.
  assign be[1] = cnn_be;
  assign be[5] = matrix_be;
  assign req[5] = mat_req;
  assign we[5] = mat_we;
  assign addr[5] = mat_addr;
  assign wdata[5] = mat_wdata;
  assign req[1] = cnn_req;
  assign we[1] = cnn_we;
  assign addr[1] = cnn_addr;
  assign wdata[1] = cnn_wdata;
  assign is_cnn_mmio = mmio_addr[11:8] == 6;
  assign we[4] = 0;
  assign be[4] = 4'hf;
  assign wdata[4] = 0;
  assign cpu_rst_n = system_rst_no && cpu_reset_count == 0;
  always_ff @(posedge clk_i or negedge system_rst_no) begin
    if (!system_rst_no) cpu_reset_count <= 0;
    else if (mmio_req && mmio_we && mmio_addr == 12'h008 && !mmio_error && !mmio_wdata[0])
      cpu_reset_count <= 4;
    else if (cpu_reset_count != 0) cpu_reset_count <= cpu_reset_count - 1'b1;
  end
  always_ff @(posedge clk_i or negedge cpu_rst_n) begin
    if (!cpu_rst_n) boot_wait <= 1;
    else if (req[4] && gnt[4] && addr[4][31:14] == 18'h20000) boot_wait <= 0;
  end
  assign removed_dma_page = mmio_addr[11:8] >= 3 && mmio_addr[11:8] <= 5;
  assign is_quant_mmio = mmio_addr[11:8] == 7;
  assign mmio_rdata = is_quant_mmio ? quant_rdata : is_cnn_mmio ? cnn_rdata : control_rdata;
  assign mmio_error = removed_dma_page || (is_quant_mmio ? quant_error : is_cnn_mmio ? cnn_error : control_error);
  assign irq_o[4:3] = 0;
  assign irq_o[2] = cnn_irq;
  assign irq_o[1] = control_irq[1];
  assign irq_o[0] = control_irq[0];
  assign sram_req_o = mem_req;
  assign sram_wen_o = mem_wen;
  assign sram_addr_o = mem_addr;
  assign sram_wdata_o = mem_wdata;
  assign mem_rdata = sram_rdata_i;
  assign cpu_test_done_o = test_result != 0;
  assign cpu_test_pass_o = test_result == 32'h600d0001;
  cv32e40p_top #(
    .COREV_PULP      (0),
    .COREV_CLUSTER   (0),
    .FPU             (0),
    .NUM_MHPMCOUNTERS(1)
  ) i_cpu (
    .clk_i              (clk_i),
    .rst_ni             (cpu_rst_n),
    .pulp_clock_en_i    (1'b1),
    .scan_cg_en_i       (1'b0),
    .boot_addr_i        (32'h00010000),
    .mtvec_addr_i       (32'h80000000),
    .dm_halt_addr_i     (dm::HaltAddress[31:0]),
    .hart_id_i          (32'b0),
    .dm_exception_addr_i(dm::ExceptionAddress[31:0]),
    .instr_req_o        (req[4]),
    .instr_gnt_i        (gnt[4]),
    .instr_rvalid_i     (rvalid[4]),
    .instr_addr_o       (addr[4]),
    .instr_rdata_i      (rdata[4]),
    .data_req_o         (req[0]),
    .data_gnt_i         (gnt[0]),
    .data_rvalid_i      (rvalid[0]),
    .data_we_o          (we[0]),
    .data_be_o          (be[0]),
    .data_addr_o        (addr[0]),
    .data_wdata_o       (wdata[0]),
    .data_rdata_i       (rdata[0]),
    .irq_i              ({(boot_wait && cpu_release), 10'b0, irq_o, 16'b0}),
    .irq_ack_o          (),
    .irq_id_o           (),
    .debug_req_i        (debug_req),
    .debug_havereset_o  (),
    .debug_running_o    (),
    .debug_halted_o     (cpu_debug_halted_o),
    .fetch_enable_i     (cpu_run_i),
    .core_sleep_o       ()
  );
  xbar #(
    .GATHER_PORTS(9),
    .NUM_MASTERS (6),
    .RF_SINK     (1)
  ) i_xbar (
    .rf_sink_be_i    (cnn_rf_sink_be),
    .rf_sink_req_i   (cnn_rf_sink_req),
    .rf_sink_addr_i  (cnn_rf_sink_addr),
    .rf_sink_wdata_i (cnn_rf_sink_wdata),
    .rf_sink_gnt_o   (cnn_rf_sink_gnt),
    .rf_sink_rvalid_o(cnn_rf_sink_rvalid),
    .rf_sink_error_o (cnn_rf_sink_error),
    .gather_req_i    (all_gather_req),
    .gather_addr_i   (all_gather_addr),
    .gather_gnt_o    (all_gather_gnt),
    .gather_valid_o  (all_gather_valid),
    .gather_error_o  (all_gather_error),
    .gather_data_o   (all_gather_data),
    .clk_i           (clk_i),
    .rst_ni          (system_rst_no),
    .req_i           (req),
    .we_i            (we),
    .be_i            (be),
    .addr_i          (addr),
    .wdata_i         (wdata),
    .gnt_o           (gnt),
    .rvalid_o        (rvalid),
    .error_o         (bus_error),
    .rdata_o         (rdata),
    .mem_req_o       (mem_req),
    .mem_wen_o       (mem_wen),
    .mem_addr_o      (mem_addr),
    .mem_wdata_o     (mem_wdata),
    .mem_rdata_i     (mem_rdata),
    .mmio_req_o      (mmio_req),
    .mmio_we_o       (mmio_we),
    .mmio_addr_o     (mmio_addr),
    .mmio_wdata_o    (mmio_wdata),
    .dm_req_o        (dm_req),
    .dm_we_o         (dm_we),
    .dm_be_o         (dm_be),
    .dm_addr_o       (dm_addr),
    .dm_wdata_o      (dm_wdata),
    .dm_rdata_i      (dm_rdata),
    .boot_rdata_i    (boot_rdata),
    .cache_hits_o    (cache_hits),
    .cache_misses_o  (cache_misses),
    .bank_accepts_o  (bank_accepts),
    .mmio_rdata_i    (mmio_rdata),
    .mmio_error_i    (mmio_error)
  );
  npu_mmio i_mmio (
    .mat_observe_i     (matrix_observe),
    .vec_observe_i     (vector_observe),
    .clk_i             (clk_i),
    .rst_ni            (system_rst_no),
    .req_i             (mmio_req && !removed_dma_page && !is_cnn_mmio && !is_quant_mmio),
    .we_i              (mmio_we),
    .addr_i            (mmio_addr),
    .wdata_i           (mmio_wdata),
    .rdata_o           (control_rdata),
    .error_o           (control_error),
    .cache_hits_i      (cache_hits),
    .cache_misses_i    (cache_misses),
    .bank_accepts_i    (bank_accepts),
    .mat_start_o       (mat_start),
    .mat_pending_o     (mat_pending),
    .vec_start_o       (vec_start),
    .mat_a_o           (ma),
    .mat_b_o           (mb),
    .mat_d_o           (md),
    .mat_m_o           (mm),
    .mat_n_o           (mn),
    .mat_k_o           (mk),
    .vec_a_o           (va),
    .vec_b_o           (vb),
    .vec_d_o           (vd),
    .vec_len_o         (vl),
    .vec_op_o          (vo),
    .vec_scalar_o      (vs),
    .vec_program_cfg_o (vector_program_cfg),
    .vec_program_o     (vector_program),
    .mat_flags_o       (mf),
    .mat_precision_o   (matrix_precision),
    .mat_element_log2_o(matrix_element_log2),
    .mat_lda_o         (matrix_lda),
    .mat_ldb_o         (matrix_ldb),
    .mat_busy_i        (mat_busy),
    .mat_blocked_i     (1'b0),
    .mat_done_i        (mat_done),
    .mat_fault_i       (mat_fault),
    .vec_busy_i        (vec_busy),
    .vec_done_i        (vec_done),
    .vec_fault_i       (vec_fault),
    .irq_o             (control_irq),
    .test_result_o     (test_result),
    .cpu_release_o     (cpu_release),
    .cpu_boot_addr_o   (cpu_boot_addr)
  );
  logic matrix_compute_valid, matrix_compute_ready, matrix_compute_flush;
  logic matrix_compute_multiply, matrix_compute_emit, matrix_result_valid, matrix_result_ready;
  logic signed [3:0][15:0] matrix_compute_a, matrix_compute_b;
  logic [31:0] matrix_compute_addend, matrix_result_data;
  logic [3:0] matrix_row_mask, matrix_col_mask, matrix_index;
  npu_matmul i_matmul (
    .row_mask_i(matrix_row_mask),
    .col_mask_i(matrix_col_mask),
    .index_i   (matrix_index),
    .clk_i,
    .rst_ni    (system_rst_no),
    .flush_i   (matrix_compute_flush),
    .valid_i   (matrix_compute_valid),
    .ready_o   (matrix_compute_ready),
    .multiply_i(matrix_compute_multiply),
    .emit_i    (matrix_compute_emit),
    .a_i       (matrix_compute_a),
    .b_i       (matrix_compute_b),
    .addend_i  (matrix_compute_addend),
    .valid_o   (matrix_result_valid),
    .ready_i   (matrix_result_ready),
    .data_o    (matrix_result_data)
  );
  npu_matrix_stream #(
    .GATHER(PARALLEL_UNITS)
  ) i_matrix_stream (
    .quant_cancelled_o     (quant_cancelled[1]),
    .observe_o             (matrix_observe),
    .quant_written_o       (quant_written[1]),
    .quant_write_fault_o   (quant_write_fault[1]),
    .quant_enable_i        (quant_enable[1]),
    .quant_pack_i          (quant_pack[1]),
    .quant_dst_i           (quant_dst[1]),
    .be_o                  (matrix_be),
    .compute_row_mask_o    (matrix_row_mask),
    .compute_col_mask_o    (matrix_col_mask),
    .compute_index_o       (matrix_index),
    .lda_i                 (matrix_lda),
    .ldb_i                 (matrix_ldb),
    .gather_req_o          (all_gather_req[5:3]),
    .gather_addr_o         (all_gather_addr[5:3]),
    .gather_gnt_i          (all_gather_gnt[5:3]),
    .gather_valid_i        (all_gather_valid[5:3]),
    .gather_error_i        (all_gather_error[5:3]),
    .gather_data_i         (all_gather_data[5:3]),
    .compute_valid_o       (matrix_compute_valid),
    .compute_ready_i       (matrix_compute_ready),
    .compute_flush_o       (matrix_compute_flush),
    .compute_multiply_o    (matrix_compute_multiply),
    .compute_emit_o        (matrix_compute_emit),
    .compute_a_o           (matrix_compute_a),
    .compute_b_o           (matrix_compute_b),
    .compute_addend_o      (matrix_compute_addend),
    .compute_result_valid_i(matrix_filtered_valid),
    .compute_result_ready_o(matrix_filtered_ready),
    .compute_result_data_i (matrix_filtered_data),

    .clk_i         (clk_i),
    .rst_ni        (system_rst_no),
    .start_i       (mat_start),
    .a_i           (ma),
    .b_i           (mb),
    .d_i           (md),
    .m_i           (mm),
    .n_i           (mn),
    .k_i           (mk),
    .flags_i       (mf),
    .precision_i   (matrix_precision),
    .element_log2_i(matrix_element_log2),
    .busy_o        (mat_busy),
    .done_o        (mat_done),
    .fault_o       (mat_fault),
    .req_o         (mat_req),
    .we_o          (mat_we),
    .addr_o        (mat_addr),
    .wdata_o       (mat_wdata),
    .gnt_i         (gnt[5]),
    .rvalid_i      (rvalid[5]),
    .error_i       (bus_error[5]),
    .rdata_i       (rdata[5])
  );
  logic
      dot_valid,
      dot_ready,
      dot_flush,
      dot_clear,
      dot_load,
      dot_emit,
      dot_result_valid,
      dot_result_ready;
  logic signed [8:0] dot_a[9], dot_offset;
  logic signed [7:0] dot_w[9];
  logic [8:0] dot_mask;
  logic [31:0] dot_seed, dot_result;
  npu_cnn i_cnn (
    .clk_i   (clk_i),
    .rst_ni  (system_rst_no),
    .flush_i (dot_flush),
    .valid_i (dot_valid),
    .ready_o (dot_ready),
    .a_i     (dot_a),
    .offset_i(dot_offset),
    .w_i     (dot_w),
    .mask_i  (dot_mask),
    .clear_i (dot_clear),
    .load_i  (dot_load),
    .emit_i  (dot_emit),
    .seed_i  (dot_seed),
    .valid_o (dot_result_valid),
    .ready_i (dot_result_ready),
    .data_o  (dot_result)
  );
  npu_stream #(
    .RF_SINK(1)
  ) i_stream (
    .quant_cancelled_o  (quant_cancelled[0]),
    .quant_written_o    (quant_written[0]),
    .quant_write_fault_o(quant_write_fault[0]),
    .result_accept_i    (dot_result_valid && dot_result_ready),
    .result_pending_i   (dot_result_valid),
    .quant_enable_i     (quant_enable[0]),
    .quant_pack_i       (quant_pack[0]),
    .quant_dst_i        (quant_dst[0]),
    .filtered_final_o   (cnn_filtered_final),
    .quant_final_o      (cnn_quant_final),
    .rf_sink_be_o       (cnn_rf_sink_be),
    .rf_sink_req_o      (cnn_rf_sink_req),
    .rf_sink_addr_o     (cnn_rf_sink_addr),
    .rf_sink_wdata_o    (cnn_rf_sink_wdata),
    .rf_sink_gnt_i      (cnn_rf_sink_gnt),
    .rf_sink_rvalid_i   (cnn_rf_sink_rvalid),
    .rf_sink_error_i    (cnn_rf_sink_error),
    .mac_valid_o        (dot_valid),
    .mac_ready_i        (dot_ready),
    .mac_flush_o        (dot_flush),
    .mac_clear_o        (dot_clear),
    .mac_load_o         (dot_load),
    .mac_emit_o         (dot_emit),
    .mac_a_o            (dot_a),
    .mac_offset_o       (dot_offset),
    .mac_w_o            (dot_w),
    .mac_mask_o         (dot_mask),
    .mac_seed_o         (dot_seed),
    .mac_result_valid_i (cnn_filtered_valid),
    .mac_result_ready_o (cnn_filtered_ready),
    .mac_result_data_i  (cnn_filtered_data),
    .gather_req_o       (cnn_gather_req),
    .gather_addr_o      (cnn_gather_addr),
    .gather_gnt_i       (cnn_gather_gnt),
    .gather_valid_i     (cnn_gather_valid),
    .gather_error_i     (cnn_gather_error),
    .gather_data_i      (cnn_gather_data),



    .clk_i      (clk_i),
    .rst_ni     (system_rst_no),
    .csr_req_i  (mmio_req && is_cnn_mmio),
    .csr_we_i   (mmio_we),
    .blocked_i  (1'b0),
    .csr_addr_i (mmio_addr[7:0]),
    .csr_wdata_i(mmio_wdata),
    .csr_rdata_o(cnn_rdata),
    .csr_error_o(cnn_error),
    .busy_o     (cnn_busy),
    .done_o     (cnn_done),
    .irq_o      (cnn_irq),
    .req_o      (cnn_req),
    .we_o       (cnn_we),
    .be_o       (cnn_be),
    .addr_o     (cnn_addr),
    .wdata_o    (cnn_wdata),
    .gnt_i      (gnt[1]),
    .rvalid_i   (rvalid[1]),
    .error_i    (bus_error[1]),
    .rdata_i    (rdata[1])
  );
  assign quant_valid = {
    matrix_result_valid && quant_enable[1], dot_result_valid && quant_enable[0] && cnn_quant_final
  };
  assign quant_in_data = {matrix_result_data, dot_result};
  assign quant_out_ready = {matrix_filtered_ready, cnn_filtered_ready};
  assign matrix_filtered_valid = quant_enable[1] ? quant_out_valid[1] : matrix_result_valid;
  assign matrix_filtered_data = quant_enable[1] ? quant_out_data[1] : matrix_result_data;
  assign matrix_result_ready = quant_enable[1] ? quant_ready[1] : matrix_filtered_ready;
  assign cnn_filtered_valid=quant_enable[0] && cnn_filtered_final ? quant_out_valid[0]:dot_result_valid;
  assign cnn_filtered_data = quant_enable[0] && cnn_filtered_final ? quant_out_data[0] : dot_result;
  assign dot_result_ready=quant_enable[0] && cnn_quant_final ? quant_ready[0]:cnn_filtered_ready;
  npu_shared_quant i_quant (
    .cancelled_i  (quant_cancelled),
    .written_i    (quant_written),
    .write_fault_i(quant_write_fault),
    .clk_i,
    .rst_ni       (system_rst_no),
    .csr_req_i    (mmio_req && is_quant_mmio),
    .csr_we_i     (mmio_we),
    .csr_addr_i   (mmio_addr[7:0]),
    .csr_wdata_i  (mmio_wdata),
    .csr_rdata_o  (quant_rdata),
    .csr_error_o  (quant_error),
    .flush_i      ({matrix_compute_flush, dot_flush}),
    .valid_i      (quant_valid),
    .ready_o      (quant_ready),
    .valid_o      (quant_out_valid),
    .ready_i      (quant_out_ready),
    .data_i       (quant_in_data),
    .data_o       (quant_out_data),
    .enable_o     (quant_enable),
    .pack_o       (quant_pack),
    .dst_o        (quant_dst)
  );
  logic [4:0] vector_compute_op;
  logic signed [31:0] vector_compute_a, vector_compute_b, vector_compute_c, vector_compute_data;
  logic vector_carry_in, vector_carry_out, vector_compute_simd;
  logic [31:0] vector_mul_a, vector_mul_b;
  npu_vector #(
    .PIPELINED_MUL(1)
  ) i_vector (
    .mul_a_i(vector_mul_a),
    .mul_b_i(vector_mul_b),
    .simd_i (vector_compute_simd),
    .op_i   (vector_compute_op),
    .a_i    (vector_compute_a),
    .b_i    (vector_compute_b),
    .c_i    (vector_compute_c),
    .carry_i(vector_carry_in),
    .carry_o(vector_carry_out),
    .data_o (vector_compute_data)
  );
  npu_vector_stream #(
    .GATHER(PARALLEL_UNITS)
  ) i_vector_stream (
    .compute_mul_a_o(vector_mul_a),
    .compute_mul_b_o(vector_mul_b),
    .observe_o      (vector_observe),
    .compute_simd_o (vector_compute_simd),
    .gather_req_o   (all_gather_req[8:6]),
    .gather_addr_o  (all_gather_addr[8:6]),
    .gather_gnt_i   (all_gather_gnt[8:6]),
    .gather_valid_i (all_gather_valid[8:6]),
    .gather_error_i (all_gather_error[8:6]),
    .gather_data_i  (all_gather_data[8:6]),
    .compute_op_o   (vector_compute_op),
    .compute_a_o    (vector_compute_a),
    .compute_b_o    (vector_compute_b),
    .compute_c_o    (vector_compute_c),
    .compute_carry_o(vector_carry_in),
    .compute_carry_i(vector_carry_out),
    .compute_data_i (vector_compute_data),

    .program_cfg_i(vector_program_cfg),
    .program_i    (vector_program),



    .be_o    (be[2]),
    .clk_i   (clk_i),
    .rst_ni  (system_rst_no),
    .start_i (vec_start),
    .a_i     (va),
    .b_i     (vb),
    .d_i     (vd),
    .len_i   (vl),
    .op_i    (vo),
    .scalar_i(vs),
    .busy_o  (vec_busy),
    .done_o  (vec_done),
    .fault_o (vec_fault),
    .req_o   (req[2]),
    .we_o    (we[2]),
    .addr_o  (addr[2]),
    .wdata_o (wdata[2]),
    .gnt_i   (gnt[2]),
    .rvalid_i(rvalid[2]),
    .error_i (bus_error[2]),
    .rdata_i (rdata[2])
  );
endmodule
