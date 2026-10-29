// ASIC integration shell. The current project RTL is kept unchanged.
// Firmware mailbox data remains accessible through JTAG/DMI/SBA.
module mynpu_asic_top #(parameter integer GRID_TOPOLOGY = 2) (
    input wire clk_i, rst_ni, boot_ready_i,
    input wire tck_i, tms_i, td_i,
    output wire td_o, npu_irq_o, cpu_debug_halted_o
);
`ifdef EDA_POSTSYN_CORE
  // Core parameters have already been resolved in the mapped netlist.
  mynpu_soc_top i_soc (
`else
  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(8192), .NPU_LANES(4),
    .DUAL_BANK_SHARED(1'b1), .NPU_MMIO_GRID(1'b1), .JTAG_BOOT_CONTROL(1'b1),
    .NPU_GRID_CACHE_WORDS(16), .NPU_GRID_TOPOLOGY(GRID_TOPOLOGY), .COMPACT_HOST_BUS(1'b1),
    .USE_ASIC_SRAM(1'b1), .USE_FPGA_BRAM(1'b0)
  ) i_soc (
`endif
    .clk_i(clk_i), .rst_ni(rst_ni), .boot_ready_i(boot_ready_i),
    .tck_i(tck_i), .tms_i(tms_i), .td_i(td_i), .td_o(td_o),
    .npu_irq_o(npu_irq_o), .cpu_debug_halted_o(cpu_debug_halted_o),
    .firmware_status_o(), .firmware_error_o(),
    .firmware_result_o(), .firmware_cycles_o()
  );
endmodule
