`timescale 1ns/1ps
// Lab6 cold load: actual TAP/DMI/SBA, CPU ROM wait, halt/load/resume, IRQ stream.
module tb_soc_jtag #(
  parameter integer MEM_BACKEND=1,SHARED=0,VECTORS=64,BOOT_ROUNDS=3
);
  logic clk=0,rst_n=0,tck=0,tms=1,tdi=0,tdo,irq,debug_halted;
  logic [31:0] cpu[0:511],model[0:2303];
  logic [7:0] inputs[0:64*784-1],gold[0:64*10-1],pt[0:64*10-1];
  logic [31:0] value,expected;
  bit allow_user_fetch=0;
  integer irq_edges=0,best,bestval;
  localparam integer MODEL_WORDS=SHARED?2304:2048;
  localparam logic [31:0] MODEL_ADDRESS=SHARED?32'h70005000:32'h70004000;
  localparam logic [31:0] INPUT_ADDRESS=SHARED?32'h70006800:32'h70005400;
  localparam logic [31:0] BUILD_ID=SHARED?32'h4a541104:32'h4a541004;
  always #10 clk=~clk;
  always @(posedge irq)irq_edges++;
  mynpu_soc_top #(.JTAG_BOOT_CONTROL(1),.DUAL_BANK_SHARED(SHARED),.NPU_LANES(4),
    .USE_FPGA_BRAM(MEM_BACKEND==1),.USE_ASIC_SRAM(MEM_BACKEND==2))dut(
    .clk_i(clk),.rst_ni(rst_n),.boot_ready_i(1'b1),
    .tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),
    .npu_irq_o(irq),.cpu_debug_halted_o(debug_halted));
  always @(posedge clk)if(rst_n&&!allow_user_fetch&&dut.instr_req&&
    dut.instr_addr>=32'h80000000&&dut.instr_addr<32'h80002000)
      $fatal(1,"CPU executed unloaded SRAM before boot release");
  `include "sim/jtag_transaction_driver.svh"
  task automatic reset_halt(input integer round);
    if(round==0||round%2==0)begin
      @(negedge clk);allow_user_fetch=0;rst_n=0;repeat(10)@(negedge clk);rst_n=1;
      repeat(20)@(negedge clk);
      init_tap(value);if(value!==1)$fatal(1,"IDCODE");
      dmi_write(7'h10,1);
    end
    // Match mynpu_reset: ndmreset preserves DM, resets RUN and all SoC clients.
    dmi_write(7'h38,32'h407000);wait_sba();
    dmi_write(7'h10,3);allow_user_fetch=0;idle_ticks(100);
    dmi_write(7'h10,32'h80000001);idle_ticks(1000);
    if(!debug_halted)$fatal(1,"CPU failed to halt after ndmreset");
    dmi_read(7'h11,value);if(!value[9])$fatal(1,"DM allhalted missing");
    sba_read(32'h10030,value);if(value!==0)$fatal(1,"Boot RUN did not reset");
    sba_read(32'h10034,value);if(value!==BUILD_ID)$fatal(1,"Build ID mismatch %h",value);
    sba_write(32'h10034,0);sba_read(32'h10034,value);
    if(value!==BUILD_ID)$fatal(1,"Build ID must be read-only");
    sba_write(32'h10000,0);sba_read(32'h10000,value);
    if(value!==32'h000102b7)$fatal(1,"Boot code must be read-only");
  endtask
  initial begin
    if(SHARED)begin
      $readmemh("generated/jtag/shared/cpu.hex",cpu);$readmemh("generated/jtag/shared/model.hex",model);
    end else begin
      $readmemh("generated/jtag/private/cpu.hex",cpu);$readmemh("generated/jtag/private/model.hex",model);
    end
    $readmemh("generated/jtag/vectors/inputs.hex",inputs);
    $readmemh("generated/jtag/vectors/integer.hex",gold);
    $readmemh("generated/jtag/vectors/pytorch.hex",pt);
    for(integer round=0;round<BOOT_ROUNDS;round++)begin
      reset_halt(round);
      $display("[JTAG-SOC] shared=%0d backend=%0d boot=%0d ROM wait/halt passed",SHARED,MEM_BACKEND,round);
      for(integer w=0;w<512;w++)begin
        sba_write(32'h80000000+w*4,cpu[w]);
        if(w%97==0)begin sba_read(32'h80000000+w*4,value);if(value!==cpu[w])$fatal(1,"CPU readback");end
      end
      for(integer w=0;w<MODEL_WORDS;w++)begin
        sba_write(MODEL_ADDRESS+w*4,model[w]);
        if(w%97==0)begin sba_read(MODEL_ADDRESS+w*4,value);if(value!==model[w])$fatal(1,"Model readback");end
      end
      for(integer w=0;w<16;w++)sba_write(32'h80001fc0+w*4,0);
      irq_edges=0;allow_user_fetch=1;sba_write(32'h10030,1);
      dmi_write(7'h10,32'h40000001);idle_ticks(1000);
      dmi_read(7'h11,value);if(!value[17])$fatal(1,"Resume ack missing");dmi_write(7'h10,1);
      for(integer k=0;k<200;k++)begin sba_read(32'h80001fc0,value);if(value==32'h5354524d)break;end
      if(value!==32'h5354524d)$fatal(1,"CPU not READY %h",value);
      $display("[JTAG-SOC] shared=%0d backend=%0d boot=%0d CPU/model loaded, CPU READY",SHARED,MEM_BACKEND,round);
      sba_read(32'h80001ffc,value);if(value!==BUILD_ID)$fatal(1,"Firmware ID");
      for(integer seq=0;seq<VECTORS;seq++)begin
        for(integer w=0;w<196;w++)begin
          for(integer b=0;b<4;b++)expected[b*8+:8]=inputs[(seq%64)*784+w*4+b];
          sba_write(INPUT_ADDRESS+w*4,expected);
        end
        sba_write(32'h80001fc0,32'h53540000+seq);
        for(integer k=0;k<300;k++)begin
          sba_read(32'h80001fc0,value);if(value==32'h444f0000+seq||value==32'hdeadbeef)break;
        end
        if(value!==32'h444f0000+seq)$fatal(1,"CPU completion seq=%0d mailbox=%h",seq,value);
        best=0;bestval=0;
        for(integer b=0;b<10;b++)begin
          sba_read(32'h80001fd0+b*4,value);
          if(value!=={24'd0,gold[(seq%64)*10+b]})$fatal(1,"Integer mismatch seq=%0d byte=%0d value=%h",seq,b,value);
          if(integer'(value)-integer'(pt[(seq%64)*10+b])>1||integer'(pt[(seq%64)*10+b])-integer'(value)>1)$fatal(1,"PyTorch tolerance");
          if(b==0||value>bestval)begin best=b;bestval=value;end
        end
        sba_read(32'h80001fc4,value);if(value!==0)$fatal(1,"CPU error field");
        sba_read(32'h80001fc8,value);if(value!==best)$fatal(1,"CPU argmax");
        sba_read(32'h80001ff8,value);if(value!==seq+1||irq_edges!=seq+1)$fatal(1,"IRQ count");
        sba_read(32'h80001fcc,value);if(value==0)$fatal(1,"NPU cycle counter");
        if(seq%8==0)$display("[JTAG-SOC] shared=%0d backend=%0d boot=%0d seq=%0d class=%0d cycles=%0d passed",SHARED,MEM_BACKEND,round,seq,best,value);
      end
      // Reset a running NPU at the next boot; stale SRAM/mailbox must not pass.
      sba_write(32'h70000000,3);
    end
    $display("[JTAG-SOC] PASS shared=%0d backend=%0d boots=%0d inferences=%0d ROM wait + ndmreset + halt/load/resume + CPU IRQ + PyTorch",SHARED,MEM_BACKEND,BOOT_ROUNDS,BOOT_ROUNDS*VECTORS);
    $finish;
  end
  initial begin #(64'd5000000000);$fatal(1,"JTAG SoC timeout");end
endmodule
