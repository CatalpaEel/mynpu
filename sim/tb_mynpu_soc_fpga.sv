`timescale 1ns/1ps

// FPGA-memory integration smoke test.  It intentionally omits DMI stimulus:
// the EGo1 shell boots the preloaded CPU image, while the separate Lab 6
// OpenOCD test exercises the exposed tck/tms/tdi/tdo pins.
module tb_mynpu_soc_fpga #(
  parameter integer BOOT_ROUNDS = 3
);
  logic clk=0, rst_ni=0;
  logic irq, halted;
  logic [31:0] firmware_status, firmware_error, firmware_result, firmware_cycles;
  logic irq_prev;
  integer irq_edges;
  always #5 clk=~clk;
  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(8192), .NPU_LANES(1),
    .USE_FPGA_BRAM(1'b1), .CPU_INIT_FILE("generated/8k/cpu.hex")
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .boot_ready_i(1'b1),
    .npu_irq_o(irq), .cpu_debug_halted_o(halted),
    .firmware_status_o(firmware_status), .firmware_error_o(firmware_error),
    .firmware_result_o(firmware_result), .firmware_cycles_o(firmware_cycles),
    .tck_i(1'b0), .tms_i(1'b1), .td_i(1'b0), .td_o()
  );
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin irq_prev<=0; irq_edges<=0; end
    else begin
      irq_prev<=irq;
      if (irq && !irq_prev) irq_edges<=irq_edges+1;
    end
  end
  task automatic reset_soc;
    @(negedge clk); rst_ni=0;
    repeat(10) @(negedge clk);
    if (firmware_status !== 0) $fatal(1,"Mailbox observer did not reset");
    rst_ni=1;
  endtask
  initial begin
    repeat(10) @(posedge clk); rst_ni=1;
    // Interrupt the first inference without reloading either SRAM. Boot code
    // must restore CPU BSS, NPU state, descriptors and input after reset.
    wait(dut.i_npu_subsystem.g_single_port.i_core.cycle_q >= 1000);
    reset_soc();
    for (integer round=0; round<BOOT_ROUNDS; round=round+1) begin
      wait(firmware_status === 32'hc0dec0de || firmware_status === 32'hdeadbeef);
      if (firmware_status === 32'hdeadbeef)
        $fatal(1,"FPGA-BRAM CPU firmware failed round=%0d code=%h",round,firmware_error);
      if (firmware_result !== 2 || irq_edges != 4 || firmware_cycles !== 288390 || firmware_error !== 0)
        $fatal(1,"FPGA reporting mismatch round=%0d result=%0d irq_edges=%0d cycles=%0d error=%h",
                 round,firmware_result,irq_edges,firmware_cycles,firmware_error);
      if (firmware_status !== dut.i_mainmem.g_fpga_bram.i_bram.mem['h1fc0/4])
        $fatal(1,"Mailbox observer disagrees with actual CPU BRAM");
      $display("[SOC-FPGA] boot=%0d CPU PASS, five inferences, irq_edges=%0d cycles=%0d",round,irq_edges,firmware_cycles);
      if (round+1<BOOT_ROUNDS) reset_soc();
    end
    $display("[SOC-FPGA] PASS boots=%0d, reset during inference, CPU BRAM + NPU BRAM, no DMI",BOOT_ROUNDS);
    $finish;
  end
  initial begin #100000000; $fatal(1,"FPGA backend timeout"); end
endmodule
