`timescale 1ns/1ps

// EGo1/Lab 6 board wrapper.
// P17 100 MHz -> Artix-7 MMCM -> 50 MHz system clock. The RISC-V Debug
// Module uses the four external J5 signals; configuration JTAG is separate.
module ego1_soc_top #(
  parameter integer CPU_SRAM_BYTES = 8192,
  parameter integer NPU_SRAM_BYTES = 8192,
  parameter integer NPU_LANES = 1,
  parameter bit USE_FPGA_BRAM = 1'b1,
  parameter CPU_INIT_FILE = "generated/8k/cpu.hex"
) (
  input  logic       fpga_clk_i,
  input  logic       rst_ni,
  input  logic       tck_i,
  input  logic       tms_i,
  input  logic       td_i,
  output logic       td_o,
  output logic [7:0] led_o
);
  logic clk_sys;
  logic clk_locked;
  logic clk_fb_mmcm, clk_fb;
  logic mmcm_clk0;
  logic sys_rst_ni;
  logic [1:0] reset_sync_q;
  logic [25:0] heartbeat_q;
  logic tck_toggle_q, tck_sync1_q, tck_sync2_q;
  logic npu_irq, cpu_debug_halted;

  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKFBOUT_MULT_F(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKIN1_PERIOD(10.0),
      .CLKOUT0_DIVIDE_F(20.0),
      .REF_JITTER1(0.010)
  ) i_mmcm (
      .CLKIN1(fpga_clk_i),
      .CLKFBIN(clk_fb),
      .RST(~rst_ni),
      .PWRDWN(1'b0),
      .CLKFBOUT(clk_fb_mmcm),
      .CLKOUT0(mmcm_clk0),
      .LOCKED(clk_locked)
  );

  BUFG i_fb_buf (.I(clk_fb_mmcm), .O(clk_fb));
  BUFG i_sys_buf (.I(mmcm_clk0), .O(clk_sys));

  // Assert immediately from reset or an unlocked MMCM; release synchronously.
  wire async_reset_ni = rst_ni & clk_locked;
  always_ff @(posedge clk_sys or negedge async_reset_ni) begin
    if (!async_reset_ni) reset_sync_q <= 2'b00;
    else reset_sync_q <= {reset_sync_q[0], 1'b1};
  end
  assign sys_rst_ni = reset_sync_q[1];

  always_ff @(posedge clk_sys or negedge sys_rst_ni) begin
    if (!sys_rst_ni) heartbeat_q <= '0;
    else heartbeat_q <= heartbeat_q + 1'b1;
  end

  // Activity indicator only; the Debug Module handles the actual JTAG CDC.
  always_ff @(posedge tck_i or negedge rst_ni) begin
    if (!rst_ni) tck_toggle_q <= 1'b0;
    else tck_toggle_q <= ~tck_toggle_q;
  end
  always_ff @(posedge clk_sys or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      tck_sync1_q <= 1'b0;
      tck_sync2_q <= 1'b0;
    end else begin
      tck_sync1_q <= tck_toggle_q;
      tck_sync2_q <= tck_sync1_q;
    end
  end

  mynpu_soc_top #(
      .CPU_SRAM_BYTES(CPU_SRAM_BYTES),
      .NPU_SRAM_BYTES(NPU_SRAM_BYTES),
      .NPU_LANES(NPU_LANES),
      .USE_FPGA_BRAM(USE_FPGA_BRAM),
      .CPU_INIT_FILE(CPU_INIT_FILE),
      .NPU_INIT_FILE("")
  ) i_soc (
      .clk_i(clk_sys),
      .rst_ni(sys_rst_ni),
      .boot_ready_i(1'b1),
      .npu_irq_o(npu_irq),
      .cpu_debug_halted_o(cpu_debug_halted),
      .tck_i(tck_i),
      .tms_i(tms_i),
      .td_i(td_i),
      .td_o(td_o)
  );

  assign led_o[0] = clk_locked;
  assign led_o[1] = heartbeat_q[25];
  assign led_o[2] = npu_irq;
  assign led_o[3] = cpu_debug_halted;
  assign led_o[4] = tck_sync2_q;
  assign led_o[7:5] = 3'b000;
endmodule
