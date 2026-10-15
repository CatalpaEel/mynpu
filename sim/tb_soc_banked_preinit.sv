`timescale 1ns/1ps
// Match the autonomous FPGA path: physical bank initialization, no SBA traffic.
module tb_soc_banked_preinit #(
  parameter integer LANES=4, ACT_CACHE_WORDS=1, BOOT_ROUNDS=21
);
  logic clk=0, rst_n=0, irq, tdo, halted, irq_prev=0;
  logic [31:0] status, error_code, result, cycles;
  integer irqs=0;
  always #10 clk=~clk;
  always @(posedge clk or negedge rst_n)
    if(!rst_n) irqs<=0;
    else if(irq && !irq_prev) irqs<=irqs+1;
  always @(posedge clk or negedge rst_n)
    if(!rst_n) irq_prev<=0;
    else irq_prev<=irq;
  mynpu_soc_top #(
    .DUAL_BANK_SHARED(1),.NPU_LANES(LANES),.NPU_ACT_CACHE_WORDS(ACT_CACHE_WORDS),
    .USE_FPGA_BRAM(1),.CPU_INIT_FILE("generated/dual-bank/cpu_bank0.hex"),
    .NPU_INIT_FILE("generated/dual-bank/cpu_bank1.hex")
  ) dut (
    .clk_i(clk),.rst_ni(rst_n),.boot_ready_i(1'b1),
    .tck_i(1'b0),.tms_i(1'b1),.td_i(1'b0),.td_o(tdo),
    .npu_irq_o(irq),.cpu_debug_halted_o(halted),
    .firmware_status_o(status),.firmware_error_o(error_code),
    .firmware_result_o(result),.firmware_cycles_o(cycles)
  );
  initial begin
    for(integer round=0;round<BOOT_ROUNDS;round++)begin
      @(negedge clk);rst_n=0;repeat(10)@(negedge clk);
      if(status!==0 || irqs!==0)$fatal(1,"mailbox/IRQ reset failed");
      rst_n=1;
      wait(status==32'hc0dec0de || status==32'hdeadbeef);
      if(status!==32'hc0dec0de || error_code!==0 || result!==2 || irqs!==5)
        $fatal(1,"preinitialized selftest failed round=%0d status=%h error=%h class=%0d IRQs=%0d",round,status,error_code,result,irqs);
      $display("[DB-PREINIT] round=%0d IRQs=%0d class=%0d cycles=%0d",round,irqs,result,cycles);
    end
    $display("[DB-PREINIT] PASS boots=%0d inferences=%0d physical FPGA bank images + CPU WFI/IRQ, no SBA",BOOT_ROUNDS,BOOT_ROUNDS*5);
    $finish;
  end
  initial begin #2000000000;$fatal(1,"preinitialized SoC timeout");end
endmodule
