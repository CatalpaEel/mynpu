// Identical hardware at every mesh coordinate. DDR is an optional external
// service on the SAME node, not a different kind of router or accelerator.
module npu_noc_core #(
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
 output logic sram_req_o,output logic [3:0] sram_wen_o,output logic [10:0] sram_addr_o,
 output logic [31:0] sram_wdata_o,input logic [31:0] sram_rdata_i,
 output logic [4:0] irq_o,output logic noc_irq_o,cpu_test_done_o,cpu_test_pass_o
);
 logic [4:0][1:0] rv,rr,tv,tr,rl,tl;
 logic [4:0][1:0][31:0] rd,td;
 assign rv[4:1]=link_rx_valid_i;assign rd[4:1]=link_rx_data_i;assign rl[4:1]=link_rx_last_i;
 assign link_rx_ready_o=rr[4:1];assign link_tx_valid_o=tv[4:1];assign link_tx_data_o=td[4:1];assign link_tx_last_o=tl[4:1];assign tr[4:1]=link_tx_ready_i;
 noc_router #(.DEPTH(ROUTER_DEPTH)) i_router(
  .clk_i,.rst_ni,.node_x_i,.node_y_i,.port_enable_i,
  .in_valid_i(rv),.in_ready_o(rr),.in_data_i(rd),.in_last_i(rl),
  .out_valid_o(tv),.out_ready_i(tr),.out_data_o(td),.out_last_o(tl)
 );
 logic noc_csr_req_o,noc_csr_we_o,noc_csr_error_i;
 logic [7:0] noc_csr_addr_o;logic [31:0] noc_csr_wdata_o,noc_csr_rdata_i;
 logic [1:0] hreq,hwe,hgnt,hvalid,herror;
 logic [1:0][3:0] hbe;logic [1:0][31:0] ha,hw,hr;
 logic core_req,core_we,core_gnt,core_valid,core_error;
 logic [3:0] core_be;logic [31:0] core_addr,core_wdata,core_rdata;
 assign hreq[0]=host_req_i;assign hwe[0]=host_we_i;assign hbe[0]=host_be_i;assign ha[0]=host_addr_i;assign hw[0]=host_wdata_i;
 assign host_gnt_o=hgnt[0];assign host_rvalid_o=hvalid[0];assign host_error_o=herror[0];assign host_rdata_o=hr[0];
 noc_host_arbiter i_host_arb(
  .clk_i,.rst_ni,.req_i(hreq),.we_i(hwe),.be_i(hbe),.addr_i(ha),.wdata_i(hw),
  .gnt_o(hgnt),.rvalid_o(hvalid),.error_o(herror),.rdata_o(hr),
  .req_o(core_req),.we_o(core_we),.be_o(core_be),.addr_o(core_addr),.wdata_o(core_wdata),
  .gnt_i(core_gnt),.rvalid_i(core_valid),.error_i(core_error),.rdata_i(core_rdata)
 );
 noc_endpoint #(.MAX_WORDS(MAX_WORDS)) i_endpoint(
  .clk_i,.rst_ni,.node_x_i,.node_y_i,.port_enable_i,.mesh_width_i,.mesh_height_i,.ddr_present_i,
  .csr_req_i(noc_csr_req_o),.csr_we_i(noc_csr_we_o),.csr_addr_i(noc_csr_addr_o),.csr_wdata_i(noc_csr_wdata_o),
  .csr_rdata_o(noc_csr_rdata_i),.csr_error_o(noc_csr_error_i),.irq_o(noc_irq_o),
  .tx_valid_o(rv[0]),.tx_ready_i(rr[0]),.tx_data_o(rd[0]),.tx_last_o(rl[0]),
  .rx_valid_i(tv[0]),.rx_ready_o(tr[0]),.rx_data_i(td[0]),.rx_last_i(tl[0]),
  .host_req_o(hreq[1]),.host_we_o(hwe[1]),.host_be_o(hbe[1]),.host_addr_o(ha[1]),.host_wdata_o(hw[1]),
  .host_gnt_i(hgnt[1]),.host_rvalid_i(hvalid[1]),.host_error_i(herror[1]),.host_rdata_i(hr[1]),
  .ddr_req_o,.ddr_we_o,.ddr_be_o,.ddr_addr_o,.ddr_wdata_o,.ddr_gnt_i,.ddr_rvalid_i,.ddr_error_i,.ddr_rdata_i
 );
 npu_core #(.NOC_ENABLE(1)) i_core(
  .clk_i,.rst_ni,.cpu_run_i,
  .host_req_i(core_req),.host_we_i(core_we),.host_be_i(core_be),.host_addr_i(core_addr),.host_wdata_i(core_wdata),
  .host_gnt_o(core_gnt),.host_rvalid_o(core_valid),.host_error_o(core_error),.host_rdata_o(core_rdata),
  .dma_rx_valid_i,.dma_rx_ready_o,.dma_rx_data_i,.dma_rx_keep_i,.dma_rx_last_i,.dma_rx_abort_o,
  .dma_tx_valid_o,.dma_tx_ready_i,.dma_tx_data_o,.dma_tx_keep_o,.dma_tx_last_o,.dma_tx_abort_o,
  .irq_o,.cpu_test_done_o,.cpu_test_pass_o,
  .noc_csr_req_o,.noc_csr_we_o,.noc_csr_addr_o,.noc_csr_wdata_o,.noc_csr_rdata_i,.noc_csr_error_i,.noc_irq_i(noc_irq_o),
  .sram_req_o,.sram_wen_o,.sram_addr_o,.sram_wdata_o,.sram_rdata_i
 );
endmodule
