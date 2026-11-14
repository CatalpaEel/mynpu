// ASIC shell: nine control/debug signals. JTAG SBA is the program/data access path.
// External access uses JTAG SBA; Host and independent DMA are removed.
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

    .irq_o          (irq),
    .cpu_test_done_o(),
    .cpu_test_pass_o()
  );
endmodule
