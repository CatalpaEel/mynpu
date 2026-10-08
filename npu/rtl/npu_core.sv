module npu_core #(parameter bit NOC_ENABLE=0) (
  input logic clk_i, rst_ni, cpu_run_i,
  input logic host_req_i, host_we_i,
  input logic [3:0] host_be_i,
  input logic [31:0] host_addr_i, host_wdata_i,
  output logic host_gnt_o, host_rvalid_o, host_error_o,
  output logic [31:0] host_rdata_o,
  input logic dma_rx_valid_i,
  output logic dma_rx_ready_o,
  input logic [31:0] dma_rx_data_i,
  input logic [3:0] dma_rx_keep_i,
  input logic dma_rx_last_i,
  output logic dma_rx_abort_o,
  output logic dma_tx_valid_o,
  input logic dma_tx_ready_i,
  output logic [31:0] dma_tx_data_o,
  output logic [3:0] dma_tx_keep_o,
  output logic dma_tx_last_o, dma_tx_abort_o,
  output logic [4:0] irq_o,
  output logic cpu_test_done_o, cpu_test_pass_o,
  output logic noc_csr_req_o,noc_csr_we_o,
  output logic [7:0] noc_csr_addr_o,output logic [31:0] noc_csr_wdata_o,
  input logic [31:0] noc_csr_rdata_i,input logic noc_csr_error_i,noc_irq_i,
  output logic sram_req_o,
  output logic [3:0] sram_wen_o,
  output logic [10:0] sram_addr_o,
  output logic [31:0] sram_wdata_o,
  input logic [31:0] sram_rdata_i
 );
  logic [7:0] req, we, gnt, rvalid, bus_error;
  logic [7:0][3:0] be;
  logic [7:0][31:0] addr, wdata, rdata;
  logic mem_req; logic [3:0] mem_wen; logic [10:0] mem_addr;
  logic [31:0] mem_wdata, mem_rdata;
  logic mmio_req, mmio_we, mmio_error;
  logic [11:0] mmio_addr;
  logic [31:0] mmio_wdata, mmio_rdata, test_result, control_rdata, dma_rdata;
  logic is_dma_mmio, control_error, dma_error, cpu_release, cpu_rst_n;
  logic [31:0] cpu_boot_addr;
  logic [2:0] dma_start, dma_abort, dma_busy, dma_done, dma_fault, dma_irq;
  logic [2:0][31:0] dma_src,dma_dst,dma_row_bytes,dma_rows,dma_src_stride,dma_dst_stride;
  logic [2:0][31:0] dma_mode,dma_fill,dma_timeout,dma_bytes_done,dma_cycles;
  logic [2:0][3:0] dma_fault_code, tx_keep;
  logic [2:0] rx_ready, tx_valid, tx_last, stream_abort;
  logic [2:0][31:0] tx_data;
  logic [1:0] control_irq;
  logic cnn_irq;
  logic cnn_busy, cnn_done, cnn_error, cnn_req, cnn_we, mat_req, mat_we;
  logic [3:0] cnn_be;
  logic [31:0] cnn_rdata, cnn_addr, cnn_wdata, mat_addr, mat_wdata;
  logic is_cnn_mmio,is_noc_mmio;
  logic mat_start, vec_start, mat_busy, mat_done, mat_fault, vec_busy, vec_done, vec_fault;
  logic [31:0] ma, mb, md, va, vb, vd;
  logic [4:0] mm, mn, mk;
  logic [10:0] vl; logic vo;
  assign req[3] = host_req_i; assign we[3] = host_we_i;
  assign be[3] = host_be_i; assign addr[3] = host_addr_i; assign wdata[3] = host_wdata_i;
  assign be[1] = cnn_busy ? cnn_be : 4'hf;
  assign req[1]=cnn_busy ? cnn_req : mat_req;
  assign we[1]=cnn_busy ? cnn_we : mat_we;
  assign addr[1]=cnn_busy ? cnn_addr : mat_addr;
  assign wdata[1]=cnn_busy ? cnn_wdata : mat_wdata;
  assign is_cnn_mmio=mmio_addr[11:8]==6; assign be[2] = 4'hf;
  assign we[4]=0; assign be[4]=4'hf; assign wdata[4]=0;
  assign cpu_rst_n = rst_ni && cpu_release;
  assign is_dma_mmio = mmio_addr[11:8] >= 3 && mmio_addr[11:8] <= 5;
  assign is_noc_mmio=NOC_ENABLE && mmio_addr[11:8]==7;
  assign noc_csr_req_o=mmio_req && is_noc_mmio;
  assign noc_csr_we_o=mmio_we;assign noc_csr_addr_o=mmio_addr[7:0];assign noc_csr_wdata_o=mmio_wdata;
  assign mmio_rdata = is_noc_mmio ? noc_csr_rdata_i : is_cnn_mmio ? cnn_rdata : is_dma_mmio ? dma_rdata : control_rdata;
  assign mmio_error = is_noc_mmio ? noc_csr_error_i : is_cnn_mmio ? cnn_error : is_dma_mmio ? dma_error : control_error;
  assign irq_o[4:2] = dma_irq;
  assign irq_o[1]=control_irq[1];assign irq_o[0]=control_irq[0] || cnn_irq;
  assign sram_req_o=mem_req;assign sram_wen_o=mem_wen;assign sram_addr_o=mem_addr;
  assign sram_wdata_o=mem_wdata;assign mem_rdata=sram_rdata_i;
  assign dma_rx_ready_o=rx_ready[0];assign dma_rx_abort_o=stream_abort[0];
  assign dma_tx_valid_o=tx_valid[1];assign dma_tx_data_o=tx_data[1];
  assign dma_tx_keep_o=tx_keep[1];assign dma_tx_last_o=tx_last[1];assign dma_tx_abort_o=stream_abort[1];
  assign host_gnt_o = gnt[3]; assign host_rvalid_o = rvalid[3];
  assign host_error_o = bus_error[3]; assign host_rdata_o = rdata[3];
  assign cpu_test_done_o = test_result != 0;
  assign cpu_test_pass_o = test_result == 32'h600d0001;
  cv32e40p_top #(.COREV_PULP(0), .COREV_CLUSTER(0), .FPU(0), .NUM_MHPMCOUNTERS(1)) i_cpu (
    .clk_i(clk_i), .rst_ni(cpu_rst_n), .pulp_clock_en_i(1'b1), .scan_cg_en_i(1'b0),
    .boot_addr_i(cpu_boot_addr), .mtvec_addr_i(32'h80000000), .dm_halt_addr_i(32'b0),
    .hart_id_i(32'b0), .dm_exception_addr_i(32'b0),
    .instr_req_o(req[4]), .instr_gnt_i(gnt[4]), .instr_rvalid_i(rvalid[4]),
    .instr_addr_o(addr[4]), .instr_rdata_i(rdata[4]),
    .data_req_o(req[0]), .data_gnt_i(gnt[0]), .data_rvalid_i(rvalid[0]),
    .data_we_o(we[0]), .data_be_o(be[0]), .data_addr_o(addr[0]),
    .data_wdata_o(wdata[0]), .data_rdata_i(rdata[0]),
    .irq_i({10'b0,(NOC_ENABLE && noc_irq_i),irq_o,16'b0}), .irq_ack_o(), .irq_id_o(),
    .debug_req_i(1'b0), .debug_havereset_o(), .debug_running_o(), .debug_halted_o(),
    .fetch_enable_i(cpu_run_i), .core_sleep_o()
  );
  nmc i_nmc (
    .clk_i(clk_i), .rst_ni(rst_ni), .req_i(req), .we_i(we), .be_i(be),
    .addr_i(addr), .wdata_i(wdata), .gnt_o(gnt), .rvalid_o(rvalid),
    .error_o(bus_error), .rdata_o(rdata), .mem_req_o(mem_req), .mem_wen_o(mem_wen),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata),
    .mmio_req_o(mmio_req), .mmio_we_o(mmio_we), .mmio_addr_o(mmio_addr),
    .mmio_wdata_o(mmio_wdata), .mmio_rdata_i(mmio_rdata), .mmio_error_i(mmio_error)
  );
  npu_mmio i_mmio (
    .clk_i(clk_i), .rst_ni(rst_ni), .req_i(mmio_req && !is_dma_mmio && !is_cnn_mmio && !is_noc_mmio), .we_i(mmio_we),
    .addr_i(mmio_addr), .wdata_i(mmio_wdata), .rdata_o(control_rdata), .error_o(control_error),
    .mat_start_o(mat_start), .vec_start_o(vec_start),
    .mat_a_o(ma), .mat_b_o(mb), .mat_d_o(md), .mat_m_o(mm), .mat_n_o(mn), .mat_k_o(mk),
    .vec_a_o(va), .vec_b_o(vb), .vec_d_o(vd), .vec_len_o(vl), .vec_op_o(vo),
    .mat_busy_i(mat_busy || cnn_busy), .mat_done_i(mat_done), .mat_fault_i(mat_fault),
    .vec_busy_i(vec_busy), .vec_done_i(vec_done), .vec_fault_i(vec_fault),
    .irq_o(control_irq), .test_result_o(test_result),
    .cpu_release_o(cpu_release), .cpu_boot_addr_o(cpu_boot_addr)
  );
  npu_matmul i_matmul (
    .clk_i(clk_i), .rst_ni(rst_ni), .start_i(mat_start),
    .a_i(ma), .b_i(mb), .d_i(md), .m_i(mm), .n_i(mn), .k_i(mk),
    .busy_o(mat_busy), .done_o(mat_done), .fault_o(mat_fault),
    .req_o(mat_req), .we_o(mat_we), .addr_o(mat_addr), .wdata_o(mat_wdata),
    .gnt_i(gnt[1]), .rvalid_i(rvalid[1]), .error_i(bus_error[1]), .rdata_i(rdata[1])
  );
  npu_cnn i_cnn (
    .clk_i(clk_i),.rst_ni(rst_ni),.csr_req_i(mmio_req && is_cnn_mmio),.csr_we_i(mmio_we),
    .blocked_i(mat_busy || mat_start),.csr_addr_i(mmio_addr[7:0]),.csr_wdata_i(mmio_wdata),
    .csr_rdata_o(cnn_rdata),.csr_error_o(cnn_error),.busy_o(cnn_busy),.done_o(cnn_done),.irq_o(cnn_irq),
    .req_o(cnn_req),.we_o(cnn_we),.be_o(cnn_be),.addr_o(cnn_addr),.wdata_o(cnn_wdata),
    .gnt_i(gnt[1]),.rvalid_i(rvalid[1]),.error_i(bus_error[1]),.rdata_i(rdata[1])
  );
  npu_vector i_vector (
    .clk_i(clk_i), .rst_ni(rst_ni), .start_i(vec_start),
    .a_i(va), .b_i(vb), .d_i(vd), .len_i(vl), .op_i(vo),
    .busy_o(vec_busy), .done_o(vec_done), .fault_o(vec_fault),
    .req_o(req[2]), .we_o(we[2]), .addr_o(addr[2]), .wdata_o(wdata[2]),
    .gnt_i(gnt[2]), .rvalid_i(rvalid[2]), .error_i(bus_error[2]), .rdata_i(rdata[2])
  );
  npu_dma_regs i_dma_regs (
    .clk_i(clk_i),.rst_ni(rst_ni),.req_i(mmio_req && is_dma_mmio),.we_i(mmio_we),
    .addr_i(mmio_addr),.wdata_i(mmio_wdata),.rdata_o(dma_rdata),.error_o(dma_error),
    .start_o(dma_start),.abort_o(dma_abort),.irq_o(dma_irq),
    .src_o(dma_src),.dst_o(dma_dst),.row_bytes_o(dma_row_bytes),.rows_o(dma_rows),
    .src_stride_o(dma_src_stride),.dst_stride_o(dma_dst_stride),.mode_o(dma_mode),
    .fill_o(dma_fill),.timeout_o(dma_timeout),.busy_i(dma_busy),.done_i(dma_done),
    .fault_i(dma_fault),.fault_code_i(dma_fault_code),.bytes_done_i(dma_bytes_done),.cycles_i(dma_cycles)
  );
  for(genvar c=0;c<3;c++) begin : gen_dma
    npu_dma_channel i_dma (
      .clk_i(clk_i),.rst_ni(rst_ni),.start_i(dma_start[c]),.abort_i(dma_abort[c]),
      .mode_i(dma_mode[c][1:0]),.src_i(dma_src[c]),.dst_i(dma_dst[c]),
      .row_bytes_i(dma_row_bytes[c]),.rows_i(dma_rows[c]),
      .src_stride_i(dma_src_stride[c]),.dst_stride_i(dma_dst_stride[c]),
      .fill_i(dma_fill[c]),.timeout_i(dma_timeout[c]),
      .busy_o(dma_busy[c]),.done_o(dma_done[c]),.fault_o(dma_fault[c]),
      .fault_code_o(dma_fault_code[c]),.bytes_done_o(dma_bytes_done[c]),.cycles_o(dma_cycles[c]),
      .rx_valid_i(c==0 ? dma_rx_valid_i : 1'b0),.rx_ready_o(rx_ready[c]),
      .rx_data_i(c==0 ? dma_rx_data_i : 32'b0),.rx_keep_i(c==0 ? dma_rx_keep_i : 4'b0),
      .rx_last_i(c==0 ? dma_rx_last_i : 1'b0),.tx_valid_o(tx_valid[c]),
      .tx_ready_i(c==1 ? dma_tx_ready_i : 1'b0),.tx_data_o(tx_data[c]),
      .tx_keep_o(tx_keep[c]),.tx_last_o(tx_last[c]),.stream_abort_o(stream_abort[c]),
      .req_o(req[c+5]),.we_o(we[c+5]),.be_o(be[c+5]),.addr_o(addr[c+5]),.wdata_o(wdata[c+5]),
      .gnt_i(gnt[c+5]),.rvalid_i(rvalid[c+5]),.error_i(bus_error[c+5]),.rdata_i(rdata[c+5])
    );
  end
endmodule
