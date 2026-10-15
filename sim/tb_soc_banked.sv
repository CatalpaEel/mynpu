`timescale 1ns/1ps
`include "generated/dual-bank/layout.svh"
module tb_soc_banked #(
  parameter integer MEM_BACKEND=1,LANES=4,STREAM=0,VECTORS=64,BOOT_ROUNDS=3,ACT_CACHE_WORDS=1
);
  logic clk=0,rst_n=0,boot_ready=0,tck=0,tms=1,tdi=0,tdo,npu_irq,debug_halted;
  logic[31:0] cpu_image[0:2047],model_image[0:4095];
  logic[7:0] inputs[0:VECTORS*784-1],gold[0:VECTORS*10-1];
  logic[31:0] value,expected;logic[40:0]scan_response;bit discard;
  integer irqs=0,dual=0,concurrent_writes=0;
  always #10 clk=~clk; // actual 50MHz
  always @(posedge npu_irq)irqs++;
  always @(posedge clk)if(rst_n&&(&dut.g_shared.i_subsystem.i_memory.bank_req))dual++;
  always @(posedge clk)if(rst_n&&dut.g_shared.i_subsystem.busy&&dut.g_shared.i_subsystem.host_write_o)concurrent_writes++;
  mynpu_soc_top #(.DUAL_BANK_SHARED(1),.NPU_LANES(LANES),.NPU_ACT_CACHE_WORDS(ACT_CACHE_WORDS),
    .USE_FPGA_BRAM(MEM_BACKEND==1),.USE_ASIC_SRAM(MEM_BACKEND==2))dut(
    .clk_i(clk),.rst_ni(rst_n),.boot_ready_i(boot_ready),.tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),
    .npu_irq_o(npu_irq),.cpu_debug_halted_o(debug_halted));
  `include "sim/db_jtag_tasks.svh"
  task automatic boot;
    @(negedge clk);boot_ready=0;rst_n=0;repeat(10)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
    repeat(6)tick(1,0,discard);tick(0,0,discard);select_ir(5'h01);scan_dr(32,0,scan_response);
    if(scan_response[31:0]!==1)$fatal(1,"JTAG IDCODE mismatch");
    select_ir(5'h11);dmi_write(7'h10,1);
    // Real SBA load into physical bank0 code alias, then model through striped
    // aliases; both FPGA and ASIC regressions exercise this exact cold path.
    for(integer i=0;i<512;i++)sba_write(32'h80000000+i*4,cpu_image[i]);
    for(integer i=0;i<16;i++)sba_write(32'h80001fc0+i*4,0);
    for(integer i='h1000/4;i<`DB_MODEL_END/4;i++)sba_write(32'h70004000+i*4,model_image[i]);
    // Explicitly verify both alias views, including a CPU-bank1 alias.
    sba_read(32'h80000800,value);if(value!==model_image['h1000/4])$fatal(1,"bank0 alias mismatch");
    sba_read(32'h80002800,value);if(value!==model_image['h1000/4+1])$fatal(1,"bank1 alias mismatch");
    irqs=0;@(negedge clk);boot_ready=1;
  endtask
  task automatic halt_resume;
    dmi_write(7'h10,32'h80000001);
    for(integer i=0;i<50;i++)begin dmi_read(7'h11,value);if(value[9])break;end
    if(!value[9])$fatal(1,"halt failed");
    dmi_write(7'h10,32'h40000001);
    for(integer i=0;i<50;i++)begin dmi_read(7'h11,value);if(value[17])break;end
    if(!value[17])$fatal(1,"resume failed");dmi_write(7'h10,1);
  endtask
  initial begin
    if(STREAM)begin
      $readmemh("generated/dual-bank/cpu_stream.hex",cpu_image);
      $readmemh("build/mnist-regression/mnist_input_codes_8k-p4.hex",inputs);
      $readmemh("build/mnist-regression/mnist_integer_outputs_8k-p4.hex",gold);
    end else $readmemh("generated/dual-bank/cpu.hex",cpu_image);
    $readmemh("generated/dual-bank/model_word.hex",model_image);
    if(STREAM)begin
      boot();
      for(integer i=0;i<200;i++)begin sba_read(32'h80001fc0,value);if(value==32'h5354524d)break;end
      if(value!==32'h5354524d)$fatal(1,"no READY %h",value);
      for(integer sample=0;sample<VECTORS;sample++)begin
        for(integer w=0;w<196;w++)begin
          for(integer b=0;b<4;b++)expected[b*8+:8]=inputs[sample*784+w*4+b];
          sba_write((32'h70004000+`DB_INPUT_BASE)+w*4,expected);
        end
        sba_write(32'h80001fc0,32'h53540000+sample);
        // Exercise both physical banks through SBA while NPU computes. Neither
        // scratch region overlaps code/stack/mailbox/model/activation storage.
        for(integer k=0;k<8;k++)begin
          expected=32'h5a000000^(sample*16+k);
          sba_write((k&1)?32'h80002400:32'h80001a00,expected);
          sba_read((k&1)?32'h80002400:32'h80001a00,value);
          if(value!==expected)$fatal(1,"CPU/NPU/SBA shared bank write lost");
        end
        if(sample%11==0)halt_resume(); // NPU continues while CPU enters debug.
        for(integer i=0;i<300;i++)begin
          sba_read(32'h80001fc0,value);if(value==32'h444f0000+sample||value==32'hdeadbeef)break;
        end
        if(value!==32'h444f0000+sample)$fatal(1,"stream timeout/failure sample=%0d value=%h",sample,value);
        for(integer i=0;i<10;i++)begin
          sba_read(32'h80001fd0+i*4,value);
          if(value!=={24'd0,gold[sample*10+i]})$fatal(1,"stream mismatch sample=%0d i=%0d got=%h",sample,i,value);
        end
        if(sample%8==0)$display("[DB-SOC] stream=%0d/%0d",sample,VECTORS);
      end
      if(irqs!=VECTORS)$fatal(1,"stream IRQs=%0d",irqs);
      if(concurrent_writes==0)$fatal(1,"stream lacked writes during active NPU");
    end else begin
      for(integer round=0;round<BOOT_ROUNDS;round++)begin
        boot();
        for(integer i=0;i<1000;i++)begin
          sba_read(32'h80001fc0,value);if(value==32'hc0dec0de||value==32'hdeadbeef)break;
        end
        if(value!==32'hc0dec0de)$fatal(1,"CPU selftest failed round=%0d mailbox=%h",round,value);
        sba_read(32'h80001ff8,value);if(value!==5||irqs!=5)$fatal(1,"CPU IRQ count=%0d edge=%0d",value,irqs);
        sba_read(32'h80001fcc,value);$display("[DB-SOC] boot=%0d IRQs=5 cycles=%0d",round,value);
        halt_resume();
        // Start an extra inference and reset with both macro/controller activity
        // in flight; next cold boot must reinitialize DM and reload both banks.
        sba_write(32'h70000000,3);repeat(37)@(negedge clk);
        if(!dut.g_shared.i_subsystem.busy)$fatal(1,"reset coverage did not hit busy");
      end
    end
    if(dual==0)$fatal(1,"SoC never used both banks");
    $display("[DB-SOC] PASS backend=%0d lanes=%0d cache=%0d stream=%0d vectors=%0d boots=%0d dual=%0d concurrent_writes=%0d CPU WFI/IRQ + JTAG/SBA + halt/resume",MEM_BACKEND,LANES,ACT_CACHE_WORDS,STREAM,VECTORS,STREAM?1:BOOT_ROUNDS,dual,concurrent_writes);$finish;
  end
  initial begin #2000000000;$fatal(1,"banked SoC timeout");end
endmodule
