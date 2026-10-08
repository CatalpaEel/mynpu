// ASIC: replace npu_tech_icg with the target library's integrated clock gate.
// FPGA: clock bypass, as in the supplied reference project; no fabric-gated clock.
module cv32e40p_clock_gate (
  input logic clk_i, en_i, scan_cg_en_i,
  output logic clk_o
);
`ifdef NPU_FPGA_TEST
  assign clk_o = clk_i;
`elsif NPU_ASIC_ICG
  npu_tech_icg i_icg (.clk_i(clk_i), .en_i(en_i), .test_en_i(scan_cg_en_i), .clk_o(clk_o));
`else
  logic enable_latched;
  always_latch if (!clk_i) enable_latched <= en_i || scan_cg_en_i;
  assign clk_o = clk_i && enable_latched;
`endif
endmodule
