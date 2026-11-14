// ASIC shell: nine control/debug signals plus eight bidirectional GPIO. JTAG SBA is the program/data access path.
// External access uses JTAG SBA; Host and independent DMA are removed.
module mynpu_asic_top (
  inout wire [7:0] gpio_io,
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
  wire [7:0] gpio_in, gpio_out, gpio_oe;
  assign npu_irq_o = |irq;
  npu_asic_top i_soc (
    .gpio_i(gpio_in), .gpio_o(gpio_out), .gpio_oe_o(gpio_oe),
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
  // One existing bidirectional IO cell per pin; input readback remains enabled.
  PDDW0204CDG i_pad_gpio0 (.I(gpio_out[0]), .OEN(~gpio_oe[0]),
    .PAD(gpio_io[0]), .C(gpio_in[0]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio1 (.I(gpio_out[1]), .OEN(~gpio_oe[1]),
    .PAD(gpio_io[1]), .C(gpio_in[1]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio2 (.I(gpio_out[2]), .OEN(~gpio_oe[2]),
    .PAD(gpio_io[2]), .C(gpio_in[2]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio3 (.I(gpio_out[3]), .OEN(~gpio_oe[3]),
    .PAD(gpio_io[3]), .C(gpio_in[3]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio4 (.I(gpio_out[4]), .OEN(~gpio_oe[4]),
    .PAD(gpio_io[4]), .C(gpio_in[4]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio5 (.I(gpio_out[5]), .OEN(~gpio_oe[5]),
    .PAD(gpio_io[5]), .C(gpio_in[5]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio6 (.I(gpio_out[6]), .OEN(~gpio_oe[6]),
    .PAD(gpio_io[6]), .C(gpio_in[6]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
  PDDW0204CDG i_pad_gpio7 (.I(gpio_out[7]), .OEN(~gpio_oe[7]),
    .PAD(gpio_io[7]), .C(gpio_in[7]), .IE(1'b1), .PE(1'b0), .DS(1'b0));
endmodule
