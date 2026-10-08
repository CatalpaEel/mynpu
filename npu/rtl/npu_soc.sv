module npu_soc (
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
  output logic cpu_test_done_o, cpu_test_pass_o
);
  logic sram_req_o;
  logic [3:0] sram_wen_o;
  logic [10:0] sram_addr_o;
  logic [31:0] sram_wdata_o,sram_rdata_i;
  logic noc_csr_req_o,noc_csr_we_o;
  logic [7:0] noc_csr_addr_o;logic [31:0] noc_csr_wdata_o;
  wire [31:0] noc_csr_rdata_i=0;wire noc_csr_error_i=1'b1,noc_irq_i=1'b0;
  npu_core i_core (.*);
  // Sole memory instance, shared by instructions, data and every DMA client.
  sram_ff #(.AddrWidth(11),.DataWidth(32),.INIT_FILE("")) i_sram (
    .clk_i(clk_i),.req_i(sram_req_o),.wen_i(sram_wen_o),.addr_i(sram_addr_o),
    .data_i(sram_wdata_o),.data_o(sram_rdata_i)
  );
endmodule
