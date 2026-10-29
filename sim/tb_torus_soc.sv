`timescale 1ns/1ps
module tb_torus_soc #(parameter MEM_BACKEND=1,VECTORS=8,EXPECT_OVERLAP=1,COMPACT_CONFIG=1,CACHE_WORDS=32,MAX_CYCLES=0);
 logic clk=0,rst_n=0,boot_ready=0,tck=0,tms=1,tdi=0,tdo,irq,halted;
 logic[31:0]firmware[0:2047],model[0:2047],value,status,fw_status,fw_error,fw_result,fw_cycles;
 logic[7:0]inputs[0:VECTORS*784-1],golden[0:VECTORS*1794-1];
 logic[40:0]scan_response;
 bit discard,running=0;
 string folder,path;
 integer sample=0,layer_index=0,checked=0,cpu_words=2048,model_words=1072,tap_all=0;
 integer overlap_start=0,config_start=0,overlap_delta=0,config_delta=0,layer_cycles=0;
 integer fast_stall[0:63],instr_stall=0,io_reads=0,io_overlap=0;
 longint unsigned clock_count=0,timer_edge[0:2];
 integer timer_reads=0,observed_cycles=0;
 logic timer_prev=0;
 integer command_streak=0,max_streak=0,commands=0,actual_cycles=0;
 always #10 clk=~clk;
 mynpu_soc_top #(.NPU_GRID_CACHE_WORDS(CACHE_WORDS),.USE_FPGA_BRAM(MEM_BACKEND==1),.USE_ASIC_SRAM(MEM_BACKEND==2))dut(
  .clk_i(clk),.rst_ni(rst_n),.boot_ready_i(boot_ready),.tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),
  .npu_irq_o(irq),.cpu_debug_halted_o(halted),.firmware_status_o(fw_status),.firmware_error_o(fw_error),
  .firmware_result_o(fw_result),.firmware_cycles_o(fw_cycles));
 `include "sim/db_jtag_tasks.svh"
 function automatic integer layer_size(input integer n);
  case(n)0:return 392;1:return 784;2:return 392;3:return 72;4:return 144;5:return 10;endcase return 0;
 endfunction
 function automatic integer layer_offset(input integer n);
  case(n)0:return 0;1:return 392;2:return 1176;3:return 1568;4:return 1640;5:return 1784;endcase return 0;
 endfunction
 function automatic integer layer_output(input integer n);return n%2==0?'h3420:'h3100;endfunction
 always @(posedge clk)begin
  clock_count++;
  timer_prev<=dut.i_cpu.core_i.csr_access_ex&&dut.i_cpu.core_i.csr_addr==12'hb00;
  if(running&&dut.i_cpu.core_i.csr_access_ex&&dut.i_cpu.core_i.csr_addr==12'hb00&&!timer_prev)begin
   if(timer_reads<3)timer_edge[timer_reads]=clock_count;
   timer_reads++;
  end
 end
 always @(posedge clk)if(rst_n)begin
  if(dut.pe_command_valid&&dut.pe_command_ready)begin commands++;command_streak++;if(command_streak>max_streak)max_streak=command_streak;end
  else command_streak=0;
  if(running)begin
   actual_cycles++;
   if(dut.instr_req&&!dut.instr_gnt)instr_stall++;
   if(dut.pe_command_valid&&!dut.pe_command_ready)fast_stall[dut.data_wdata[31:26]]++;
   for(integer p=0;p<2;p++)if(dut.g_shared.i_subsystem.io_req[p]&&dut.g_shared.i_subsystem.gnt[p+1]&&!dut.g_shared.i_subsystem.io_we[p])begin
    io_reads++;
    if(dut.pe_command_valid&&dut.pe_command_ready&&dut.data_wdata[31:26]<=52&&(|dut.data_wdata[13:10]))io_overlap++;
   end
  end
  if(dut.g_shared.host_write&&dut.g_shared.host_addr=='h80001ffc)layer_index=dut.g_shared.host_wd;
  for(integer p=0;p<2;p++)if(running&&dut.g_shared.i_subsystem.io_req[p]&&dut.g_shared.i_subsystem.io_we[p]&&dut.g_shared.i_subsystem.gnt[p+1])begin
   integer index,expected;
   index=dut.g_shared.i_subsystem.io_addr[p]-layer_output(layer_index);
   for(integer b=0;b<4;b++)if(dut.g_shared.i_subsystem.io_be[p][b])begin
    if(index+b<0||index+b>=layer_size(layer_index))$fatal(1,"output out of layer bounds");
    expected=golden[sample*1794+layer_offset(layer_index)+index+b];
    if(dut.g_shared.i_subsystem.io_wd[p][b*8+:8]!==expected[7:0])$fatal(1,"torus layer mismatch sample=%0d layer=%0d index=%0d got=%0d expected=%0d",sample,layer_index,index+b,dut.g_shared.i_subsystem.io_wd[p][b*8+:8],expected);
    checked++;
   end
  end
 end
 task automatic snapshot(input integer li);
  for(integer i=0;i<(layer_size(li)+3)/4;i++)begin
   sba_read('h80003800+layer_offset(li)+i*4,value);
   for(integer b=0;b<4;b++)if(i*4+b<layer_size(li)&&value[b*8+:8]!==golden[sample*1794+layer_offset(li)+i*4+b])$fatal(1,"torus snapshot mismatch layer=%0d",li);
  end
 endtask
 initial begin
  if(!$value$plusargs("FOLDER=%s",folder))$fatal(1,"FOLDER missing");
  if($value$plusargs("CPU_WORDS=%d",cpu_words));if($value$plusargs("MODEL_WORDS=%d",model_words));if($value$plusargs("TAP_ALL=%d",tap_all));
  path={folder,"/cpu.hex"};$readmemh(path,firmware);path={folder,"/model.hex"};$readmemh(path,model);
  path={folder,"/inputs.hex"};$readmemh(path,inputs);path={folder,"/golden.hex"};$readmemh(path,golden);
  repeat(10)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
  repeat(6)tick(1,0,discard);tick(0,0,discard);select_ir(1);scan_dr(32,0,scan_response);
  if(scan_response[31:0]!=1)$fatal(1,"JTAG IDCODE mismatch");
  select_ir('h11);dmi_write('h10,1);
  for(integer i=0;i<cpu_words;i++)sba_write('h80000000+i*4,firmware[i]);
  for(integer i=0;i<16;i++)sba_write('h80001fc0+i*4,0);
  for(integer i=0;i<model_words;i++)sba_write('h80002000+i*4,model[i]);
  // CPU and NPU aliases must read the SAME physical word.
  sba_read('h70006000,value);if(value!==model[0])$fatal(1,"bank-linear alias mismatch");
  boot_ready=1;sba_write('h10030,1);
  for(integer i=0;i<100;i++)begin sba_read('h80001fc0,value);if(value=='h544f5252||value=='hdeadbeef)break;end
  if(value!=='h544f5252)$fatal(1,"CPU not READY status=%h error=%h",value,fw_error);
  $display("TORUS-CPU-ISSUE peak_consecutive=%0d burst_result=64",max_streak);
  dmi_write('h10,'h80000001);
  for(integer i=0;i<50;i++)begin dmi_read('h11,value);if(value[9])break;end
  if(!value[9])$fatal(1,"CPU did not halt");
  sba_read('h70000000,value);if(value!='h544f5204)$fatal(1,"torus capability mismatch");
  dmi_write('h10,'h40000001);
  for(integer i=0;i<50;i++)begin dmi_read('h11,value);if(value[17])break;end
  if(!value[17])$fatal(1,"CPU did not resume");dmi_write('h10,1);
  for(sample=0;sample<VECTORS;sample++)begin
   for(integer i=0;i<196;i++)begin
    value=0;for(integer b=0;b<4;b++)value[b*8+:8]=inputs[sample*784+i*4+b];
    sba_write('h80003100+i*4,value);
   end
   sba_write('h80001fc4,tap_all?1:0);
   overlap_start=dut.g_shared.i_subsystem.overlap_count_q;config_start=dut.g_shared.i_subsystem.descriptor_count_q;
   for(integer op=0;op<64;op++)fast_stall[op]=0;instr_stall=0;io_reads=0;io_overlap=0;
   timer_reads=0;actual_cycles=0;running=1;sba_write('h80001fc0,'h53540000+sample);
   for(integer i=0;i<4;i++)begin
    sba_write('h80003f80,'hcafe0000+i);sba_read('h70007f80,value);
    if(value!=='hcafe0000+i)$fatal(1,"Concurrent SBA word lost");
   end
   for(integer guard=0;guard<2000;guard++)begin
    sba_read('h80001fc0,status);if(status=='hdeadbeef||status=='h444f0000+sample)break;
   end
   running=0;
   if(status!='h444f0000+sample)$fatal(1,"CPU inference failed status=%h error=%h",status,fw_error);
   for(integer i=0;i<3;i++)begin
    sba_read('h80003100+i*4,value);
    for(integer b=0;b<4;b++)if(i*4+b<10&&value[b*8+:8]!==golden[sample*1794+1784+i*4+b])$fatal(1,"torus final SRAM mismatch");
   end
   begin
    integer best;best=0;for(integer i=1;i<10;i++)if(golden[sample*1794+1784+i]>golden[sample*1794+1784+best])best=i;
    if(fw_result!==best)$fatal(1,"CPU argmax mismatch");
   end
   if(tap_all)for(integer li=0;li<6;li++)snapshot(li);
   if(timer_reads!=3)$fatal(1,"Expected three software mcycle reads, got %0d",timer_reads);
   observed_cycles=timer_edge[2]-timer_edge[0];
   if(observed_cycles+2<fw_cycles||observed_cycles>fw_cycles+2)$fatal(1,"Cycle report differs from independent clock count fw=%0d clocks=%0d",fw_cycles,observed_cycles);
   if(MAX_CYCLES>0&&(fw_cycles>=MAX_CYCLES||observed_cycles>=MAX_CYCLES))$fatal(1,"Inference exceeds strict cycle limit fw=%0d clocks=%0d limit=%0d",fw_cycles,observed_cycles,MAX_CYCLES);
   $display("TORUS-LIMIT firmware=%0d observed=%0d limit=%0d",fw_cycles,observed_cycles,MAX_CYCLES);
   overlap_delta=dut.g_shared.i_subsystem.overlap_count_q-overlap_start;
   config_delta=dut.g_shared.i_subsystem.descriptor_count_q-config_start;
   sba_read('h80001fd0,value);layer_cycles=value;
   $display("TORUS-PROFILE instr_stall=%0d io_reads=%0d simultaneous_read_compute=%0d stall_mac=%0d stall_exchange=%0d stall_commit=%0d",instr_stall,io_reads,io_overlap,fast_stall[6],fast_stall[58],fast_stall[59]);
   if(EXPECT_OVERLAP&&overlap_delta==0)$fatal(1,"No actual compute/load overlap");
   if(!EXPECT_OVERLAP&&overlap_delta!=0)$fatal(1,"Unexpected overlap in serial reference");
   if(COMPACT_CONFIG&&config_delta>1200)$fatal(1,"Repeated descriptor configuration regressed");
   $display("TORUS-SOC sample=%0d cycles=%0d layer_cycles=%0d wall_cycles=%0d overlap=%0d config_writes=%0d backend=%0d",sample,fw_cycles,layer_cycles,actual_cycles,overlap_delta,config_delta,MEM_BACKEND);
  end
  if(checked!=VECTORS*1794)$fatal(1,"Missing layer coverage got=%0d expected=%0d",checked,VECTORS*1794);
  $display("TORUS-SOC-PASS backend=%0d vectors=%0d checked=%0d commands=%0d CPU-SRAM/MMIO/local-RF/quant-in-PE/JTAG-SBA/halt-resume",MEM_BACKEND,VECTORS,checked,commands);$finish;
 end
 initial begin #(64'd20000000000);$fatal(1,"torus SoC watchdog");end
endmodule
