`timescale 1ns/1ps

// EGo1 autonomous prototype.  No external RISC-V Debug Module signals are
// required: the CPU image contains the model constants in BRAM, and the CPU
// loads the NPU SRAM over AXI before inference. The
// existing firmware runs the fixed five-inference self-test after reset.
// LED[3:0] is a saturating count of NPU completion IRQs; the expected value
// after the self-test is 4. LED[6] is CPU-verified PASS; LED[7] is FAIL/timeout.
module ego1_autonomous_top #(
  parameter integer CPU_SRAM_BYTES = 8192,
  parameter integer NPU_SRAM_BYTES = 8192,
  parameter integer NPU_LANES = 1,
  parameter bit USE_FPGA_BRAM = 1'b1,
  parameter CPU_INIT_FILE = "generated/8k/cpu.hex",
  parameter integer SELFTEST_TIMEOUT_CYCLES = 250000000
) (
  input  logic fpga_clk_i,
  input  logic rst_ni,
  output logic [7:0] led_o
);
  logic clk_sys, clk_locked, clk_fb_mmcm, clk_fb, mmcm_clk0;
  logic sys_rst_ni;
  (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_q;
  logic [25:0] heartbeat_q;
  logic [3:0] irq_count_q;
  logic irq_prev_q, soft_reset;
  logic [31:0] firmware_status, firmware_error, firmware_result, firmware_cycles;
  logic [31:0] watchdog_q;
  logic timeout_q;
  logic npu_irq, cpu_debug_halted;
  logic unused_tdo;

  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"), .CLKFBOUT_MULT_F(10.0), .DIVCLK_DIVIDE(1),
      .CLKIN1_PERIOD(10.0), .CLKOUT0_DIVIDE_F(20.0), .REF_JITTER1(0.010)
  ) i_mmcm (
      .CLKIN1(fpga_clk_i), .CLKFBIN(clk_fb), .RST(~rst_ni), .PWRDWN(1'b0),
      .CLKFBOUT(clk_fb_mmcm), .CLKOUT0(mmcm_clk0), .LOCKED(clk_locked)
  );
  BUFG i_fb_buf (.I(clk_fb_mmcm), .O(clk_fb));
  BUFG i_sys_buf (.I(mmcm_clk0), .O(clk_sys));

  wire async_reset_ni = rst_ni & clk_locked & ~soft_reset;
  always_ff @(posedge clk_sys or negedge async_reset_ni) begin
    if (!async_reset_ni) reset_sync_q <= 2'b00;
    else reset_sync_q <= {reset_sync_q[0], 1'b1};
  end
  assign sys_rst_ni = reset_sync_q[1];

  always_ff @(posedge clk_sys or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      heartbeat_q <= '0;
      irq_count_q <= '0;
      irq_prev_q <= 1'b0;
      watchdog_q <= '0;
      timeout_q <= 1'b0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;
      irq_prev_q <= npu_irq;
      // The NPU IRQ is a level until cleared by the CPU handler.
      if (npu_irq && !irq_prev_q && (irq_count_q != 4'hf))
        irq_count_q <= irq_count_q + 1'b1;
      if (firmware_status != 32'hc0dec0de && firmware_status != 32'hdeadbeef) begin
        if (watchdog_q == SELFTEST_TIMEOUT_CYCLES - 1) timeout_q <= 1'b1;
        else if (!timeout_q) watchdog_q <= watchdog_q + 1'b1;
      end
    end
  end

  // TCK is held low and TMS high, which leaves the unused DMI TAP idle while
  // preserving the same reset behavior as the debug-capable top level.
  mynpu_soc_top #(
      .CPU_SRAM_BYTES(CPU_SRAM_BYTES), .NPU_SRAM_BYTES(NPU_SRAM_BYTES),
      .NPU_LANES(NPU_LANES), .USE_FPGA_BRAM(USE_FPGA_BRAM),
      .CPU_INIT_FILE(CPU_INIT_FILE), .NPU_INIT_FILE("")
  ) i_soc (
      .clk_i(clk_sys), .rst_ni(sys_rst_ni), .boot_ready_i(1'b1),
      .npu_irq_o(npu_irq), .cpu_debug_halted_o(cpu_debug_halted),
      .firmware_status_o(firmware_status), .firmware_error_o(firmware_error),
      .firmware_result_o(firmware_result), .firmware_cycles_o(firmware_cycles),
      .tck_i(1'b0), .tms_i(1'b1), .td_i(1'b0), .td_o(unused_tdo)
  );

  // FPGA-only VIO uses the board's configuration JTAG. It can read the
  // mailbox and reset the SoC without using the RISC-V Debug Module.
  vio_autonomous i_vio (
      .clk(clk_sys), .probe_in0(firmware_status), .probe_in1(firmware_error),
      .probe_in2(irq_count_q), .probe_in3(firmware_result),
      .probe_in4(firmware_cycles), .probe_in5(timeout_q),
      .probe_out0(soft_reset)
  );

  assign led_o[3:0] = irq_count_q;
  assign led_o[4] = heartbeat_q[25];
  assign led_o[5] = clk_locked;
  assign led_o[6] = (firmware_status == 32'hc0dec0de) && !timeout_q;
  assign led_o[7] = (firmware_status == 32'hdeadbeef) || timeout_q;
endmodule
