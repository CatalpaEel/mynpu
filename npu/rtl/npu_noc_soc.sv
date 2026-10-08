// Identical hardware at every mesh coordinate. DDR is an optional external
// service on the SAME node, not a different kind of router or accelerator.
module npu_noc_soc #(
 parameter int ROUTER_DEPTH=2,MAX_WORDS=16
)(
 input logic clk_i,rst_ni,cpu_run_i,
 input logic [3:0] node_x_i,node_y_i,
 input logic [4:0] port_enable_i,mesh_width_i,mesh_height_i,
 input logic ddr_present_i,
 input logic [3:0][1:0] link_rx_valid_i,output logic [3:0][1:0] link_rx_ready_o,
 input logic [3:0][1:0][31:0] link_rx_data_i,input logic [3:0][1:0] link_rx_last_i,
 output logic [3:0][1:0] link_tx_valid_o,input logic [3:0][1:0] link_tx_ready_i,
 output logic [3:0][1:0][31:0] link_tx_data_o,output logic [3:0][1:0] link_tx_last_o,
 input logic host_req_i,host_we_i,input logic [3:0] host_be_i,
 input logic [31:0] host_addr_i,host_wdata_i,
 output logic host_gnt_o,host_rvalid_o,host_error_o,output logic [31:0] host_rdata_o,
 output logic ddr_req_o,ddr_we_o,output logic [3:0] ddr_be_o,
 output logic [31:0] ddr_addr_o,ddr_wdata_o,
 input logic ddr_gnt_i,ddr_rvalid_i,ddr_error_i,input logic [31:0] ddr_rdata_i,
 // Original stream DMA interfaces remain available for board adapters.
 input logic dma_rx_valid_i,output logic dma_rx_ready_o,
 input logic [31:0] dma_rx_data_i,input logic [3:0] dma_rx_keep_i,input logic dma_rx_last_i,
 output logic dma_rx_abort_o,dma_tx_valid_o,input logic dma_tx_ready_i,
 output logic [31:0] dma_tx_data_o,output logic [3:0] dma_tx_keep_o,
 output logic dma_tx_last_o,dma_tx_abort_o,
 output logic [4:0] irq_o,output logic noc_irq_o,cpu_test_done_o,cpu_test_pass_o
);
 logic sram_req_o;logic [3:0] sram_wen_o;logic [10:0] sram_addr_o;
 logic [31:0] sram_wdata_o,sram_rdata_i;
 npu_noc_core #(.ROUTER_DEPTH(ROUTER_DEPTH),.MAX_WORDS(MAX_WORDS)) i_node(.*);
 sram_ff #(.AddrWidth(11),.DataWidth(32),.INIT_FILE("")) i_sram(
  .clk_i,.req_i(sram_req_o),.wen_i(sram_wen_o),.addr_i(sram_addr_o),.data_i(sram_wdata_o),.data_o(sram_rdata_i)
 );
endmodule
