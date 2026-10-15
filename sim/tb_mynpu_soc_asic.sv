`timescale 1ns/1ps

// ASIC-memory integration smoke test.  Compile this testbench together with
// the foundry-provided RA1SHD_2048x32M8.v model (kept outside the repository).
// It boots the same five-run CPU firmware used by the functional and FPGA
// tests, so both CPU and NPU SRAM wrappers are exercised.
module tb_mynpu_soc_asic;
  logic clk=0, rst_ni=0, irq, halted;
  always #5 clk=~clk;
  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(8192), .NPU_LANES(1),
    .USE_ASIC_SRAM(1'b1), .CPU_INIT_FILE("generated/8k/cpu.hex")
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .boot_ready_i(1'b1),
    .npu_irq_o(irq), .cpu_debug_halted_o(halted),
    .tck_i(1'b0), .tms_i(1'b1), .td_i(1'b0), .td_o()
  );
  initial begin
    repeat(10) @(posedge clk); rst_ni=1;
    wait(dut.g_private.i_mainmem.g_asic_macro.i_macro.i_macro.mem['h1fc0/4] === 32'hc0dec0de ||
         dut.g_private.i_mainmem.g_asic_macro.i_macro.i_macro.mem['h1fc0/4] === 32'hdeadbeef);
    if (dut.g_private.i_mainmem.g_asic_macro.i_macro.i_macro.mem['h1fc0/4] === 32'hdeadbeef)
      $fatal(1,"ASIC-SRAM CPU firmware failed code=%h",dut.g_private.i_mainmem.g_asic_macro.i_macro.i_macro.mem['h1fc4/4]);
    $display("[SOC-ASIC] PASS CPU + NPU foundry SRAM wrappers, NPU cycles=%0d", dut.g_private.i_npu_subsystem.g_single_port.i_core.cycle_q);
    $finish;
  end
  initial begin #100000000; $fatal(1,"ASIC backend timeout"); end
endmodule
