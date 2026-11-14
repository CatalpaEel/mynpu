module npu_soc (
  input logic [7:0] gpio_i,
  output logic [7:0] gpio_o, gpio_oe_o,
  input logic clk_i,
  rst_ni,
  cpu_run_i,
  input logic tck_i,
  tms_i,
  td_i,
  output logic td_o,
  cpu_debug_halted_o,
  output logic [4:0] irq_o,
  output logic cpu_test_done_o,
  cpu_test_pass_o
);
  logic system_rst_no;
  logic [1:0] sram_req_o;
  logic [1:0][3:0] sram_wen_o;
  logic [1:0][10:0] sram_addr_o;
  logic [1:0][31:0] sram_wdata_o, sram_rdata_i;
  npu_core i_core (.*);
  // Two physical SRAM banks, shared by instructions, data and NPU.
  for (genvar b = 0; b < 2; b++) begin : g_bank
    sram_ff #(
      .AddrWidth(11),
      .DataWidth(32),
      .INIT_FILE("")
    ) i_sram (
      .clk_i (clk_i),
      .req_i (sram_req_o[b]),
      .wen_i (sram_wen_o[b]),
      .addr_i(sram_addr_o[b]),
      .data_i(sram_wdata_o[b]),
      .data_o(sram_rdata_i[b])
    );
  end
endmodule
