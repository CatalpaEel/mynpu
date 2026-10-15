`timescale 1ns/1ps
`include "generated/dual-bank/layout.svh"
module tb_npu_banked #(parameter integer MEM_BACKEND=1,LANES=4,RUNS=100,HOST_TRAFFIC=1,ACT_CACHE_WORDS=1);
  logic clk=0,rst=0,req=0,we=0,gnt,rv,err,irq,hw;
  logic[31:0] addr=0,wd=0,rd,ha,hwd;
  logic[3:0] be=15,hbe;
  logic[31:0] image[0:4095];logic[7:0] golden[0:1793],pt[0:1793];
  integer dual_cycles=0,macs=0,checks=0,previous_layer=0;
  integer same_bank[0:5],different_bank[0:5],cache_hits[0:5],wait_cycles[0:5];
  always #5 clk=~clk;
  mynpu_shared_subsystem #(.LANES(LANES),.MEM_BACKEND(MEM_BACKEND),.ACT_CACHE_WORDS(ACT_CACHE_WORDS)) dut(
    .clk_i(clk),.rst_ni(rst),.req_i(req),.we_i(we),.addr_i(addr),.wdata_i(wd),.be_i(be),
    .gnt_o(gnt),.rvalid_o(rv),.error_o(err),.rdata_o(rd),.irq_o(irq),
    .host_write_o(hw),.host_addr_o(ha),.host_wdata_o(hwd),.host_be_o(hbe));
  always @(posedge clk)if(rst)begin
    if(&dut.i_memory.bank_req)dual_cycles++;
    if(dut.i_core.mac_enable)macs+=dut.i_core.count_q;
    if(dut.i_core.state_q==dut.i_core.TERM&&!dut.i_core.padding)begin
      if(dut.i_core.cache_hit)cache_hits[dut.i_core.layer_q]++;
      else if((dut.i_core.weight_addr&4)==(dut.i_core.act_addr&4))same_bank[dut.i_core.layer_q]++;
      else different_bank[dut.i_core.layer_q]++;
    end
    if(dut.busy&&(|(dut.eng_req&~dut.gnt[2:1])))wait_cycles[dut.i_core.layer_q]++;
    if(dut.eng_req[0]&&dut.gnt[1]&&dut.eng_we[0])begin : check_layer_write
      integer offset,index,actual,delta;
      case(dut.i_core.layer_q)
        0:offset=0;1:offset=392;2:offset=1176;3:offset=1568;4:offset=1640;5:offset=1784;
        default:$fatal(1,"invalid layer");
      endcase
      index=offset+dut.i_core.out_addr-dut.i_core.ob_q;
      actual=dut.eng_wd[0][(dut.i_core.out_addr&3)*8+:8];
      if(actual!==integer'(golden[index]))$fatal(1,"layer=%0d output=%0d integer mismatch",dut.i_core.layer_q,index);
      delta=actual-integer'(pt[index]);if(delta< -1||delta>1)$fatal(1,"PyTorch layer mismatch");
      checks++;
    end
  end
  task automatic access(input bit wr,input logic[31:0] a,d,output logic[31:0] result);
    @(negedge clk);req=1;we=wr;addr=a;wd=d;
    do @(posedge clk);while(!gnt);
    @(negedge clk);req=0;we=0;
    while(!rv)@(negedge clk);
    result=rd;if(err)$fatal(1,"host error %h",a);
    @(negedge clk);
  endtask
  logic[31:0] value,status,cycles;
  initial begin
    for(integer l=0;l<6;l++)begin same_bank[l]=0;different_bank[l]=0;cache_hits[l]=0;wait_cycles[l]=0;end
    $readmemh("generated/dual-bank/model_word.hex",image);
    $readmemh("generated/dual-bank/integer_layers.hex",golden);
    $readmemh("generated/dual-bank/pytorch_layers.hex",pt);
    repeat(4)@(negedge clk);rst=1;
    for(integer i=0;i<4096;i++)access(1,32'h70004000+i*4,image[i],value);
    access(1,32'h70000010,`DB_DESC_BASE,value);access(1,32'h70000014,6,value);
    for(integer run=0;run<RUNS;run++)begin
      if(run%11==10)begin
        @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;
        access(1,32'h70000010,`DB_DESC_BASE,value);access(1,32'h70000014,6,value);
      end
      for(integer i=0;i<196;i++)access(1,(32'h70004000+`DB_INPUT_BASE)+i*4,image[`DB_INPUT_BASE/4+i],value);
      access(1,32'h70000000,3,value);
      // Host accesses both banks while NPU is busy; these cells are outside all
      // descriptors, weights, activations, CPU code and mailbox reservations.
      for(integer i=0;i<(HOST_TRAFFIC?64:0);i++)begin
        access(1,32'h70007800+(i%2)*4,32'habcd0000+i,value);
        access(0,32'h70007800+(i%2)*4,0,value);
        if(value!==32'habcd0000+i)$fatal(1,"concurrent host word lost");
      end
      do access(0,32'h70000004,0,status);while(!status[1]&&!status[2]);
      if(status[2]||!irq)$fatal(1,"inference error run=%0d status=%h",run,status);
      for(integer i=0;i<3;i++)begin
        access(0,(32'h70004000+`DB_INPUT_BASE)+i*4,0,value);
        for(integer b=0;b<4;b++)if(i*4+b<10)begin
          if(value[b*8+:8]!==golden[1784+i*4+b])$fatal(1,"output mismatch run=%0d i=%0d got=%h",run,i*4+b,value);
        end
      end
      access(0,32'h70000018,0,cycles);access(1,32'h70000000,4,value);
      if(run%25==24)$display("[DB-NPU] run=%0d cycles=%0d",run+1,cycles);
    end
    // Physical CPU aliases must invalidate matching striped cache tags, even
    // when writing the same data. Probe retained lines after the final DONE.
    begin : check_alias_snoop
      integer tested,logical_word,physical_address;
      tested=0;
      for(integer c=0;c<ACT_CACHE_WORDS;c++)if(dut.i_core.cache_valid_q[c])begin
        logical_word=dut.i_core.cache_tag_q[c];
        physical_address=32'h80000000+((logical_word&1)?8192:0)+(logical_word>>1)*4;
        access(1,physical_address,dut.i_core.cache_data_q[c],value);
        if(dut.i_core.cache_valid_q[c])$fatal(1,"CPU physical alias failed to invalidate activation cache");
        tested++;
      end
      if(tested==0)$fatal(1,"cache snoop coverage missing");
    end
    if(dual_cycles==0||macs!=RUNS*40770||checks!=RUNS*1794)$fatal(1,"missing dual-bank/MAC/layer coverage dual=%0d macs=%0d",dual_cycles,macs);
    for(integer l=0;l<6;l++)$display("[DB-PROFILE] layer=%0d runs=%0d same_bank_terms=%0d different_bank_terms=%0d cache_hits=%0d engine_wait_cycles=%0d",l,RUNS,same_bank[l],different_bank[l],cache_hits[l],wait_cycles[l]);
    $display("[DB-NPU] PASS backend=%0d lanes=%0d runs=%0d cycles=%0d dual_bank_cycles=%0d MACs=%0d",MEM_BACKEND,LANES,RUNS,cycles,dual_cycles,macs);
    $finish;
  end
  initial begin #500000000;$fatal(1,"banked NPU timeout");end
endmodule
