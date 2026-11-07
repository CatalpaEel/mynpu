// Nine-signal ASIC shell. JTAG SBA is the program/data access path.
// Test-host access is tied off; independent DMA hardware has been removed.
module mynpu_asic_top (
  input wire clk_i,
  rst_ni,
  boot_ready_i,
  input wire tck_i,
  tms_i,
  td_i,
  output wire td_o,
  npu_irq_o,
  cpu_debug_halted_o
);
  wire [4:0] irq;
  assign npu_irq_o = |irq;
  npu_asic_top i_soc (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .cpu_run_i         (boot_ready_i),
    .tck_i             (tck_i),
    .tms_i             (tms_i),
    .td_i              (td_i),
    .td_o              (td_o),
    .cpu_debug_halted_o(cpu_debug_halted_o),
    .host_req_i        (1'b0),
    .host_we_i         (1'b0),
    .host_be_i         (4'b0),
    .host_addr_i       (32'b0),
    .host_wdata_i      (32'b0),
    .host_gnt_o        (),
    .host_rvalid_o     (),
    .host_error_o      (),
    .host_rdata_o      (),












    .irq_o          (irq),
    .cpu_test_done_o(),
    .cpu_test_pass_o()
  );
endmodule
