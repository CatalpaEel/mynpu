`timescale 1ns/1ps
module tb_npu_banked_random #(parameter integer MEM_BACKEND=1,LANES=4,CASES=200,ACT_CACHE_WORDS=1);
  logic clk=0,rst=0,req=0,we=0,gnt,rv,err,irq,hw;
  logic[31:0] addr=0,wd=0,rd,ha,hwd;logic[3:0]be=15,hbe;
  logic[31:0] inputs[0:CASES*4096-1],gold[0:CASES*4096-1];
  logic[31:0] value,status;integer irqs=0,dual=0;
  always #5 clk=~clk;always @(posedge irq)irqs++;
  always @(posedge clk)if(rst&&(&dut.i_memory.bank_req))dual++;
  mynpu_shared_subsystem #(.LANES(LANES),.MEM_BACKEND(MEM_BACKEND),.ACT_CACHE_WORDS(ACT_CACHE_WORDS))dut(
    .clk_i(clk),.rst_ni(rst),.req_i(req),.we_i(we),.addr_i(addr),.wdata_i(wd),.be_i(be),
    .gnt_o(gnt),.rvalid_o(rv),.error_o(err),.rdata_o(rd),.irq_o(irq),
    .host_write_o(hw),.host_addr_o(ha),.host_wdata_o(hwd),.host_be_o(hbe));
  task automatic access(input bit wr,input logic[31:0]a,d,output logic[31:0]result);
    @(negedge clk);req=1;we=wr;addr=a;wd=d;
    do @(posedge clk);while(!gnt);
    @(negedge clk);req=0;we=0;while(!rv)@(negedge clk);
    result=rd;if(err)$fatal(1,"host error");@(negedge clk);
  endtask
  initial begin
    $readmemh("build/npu-banked-stress/input.hex",inputs);
    $readmemh("build/npu-banked-stress/expected.hex",gold);
    repeat(4)@(negedge clk);rst=1;
    for(integer c=0;c<CASES;c++)begin
      for(integer w=0;w<4096;w++)access(1,32'h70004000+w*4,inputs[c*4096+w],value);
      access(1,32'h70000010,0,value);access(1,32'h70000014,1,value);access(1,32'h70000000,3,value);
      status=0;for(integer p=0;p<100000;p++)begin
        access(0,32'h70000004,0,status);if(status[1]||status[2])break;
      end
      if(status[2]||!status[1]||!irq)$fatal(1,"random failed case=%0d status=%h",c,status);
      for(integer w=0;w<4096;w++)begin
        access(0,32'h70004000+w*4,0,value);
        if(value!==gold[c*4096+w])$fatal(1,"random case=%0d word=%0d hw=%h ref=%h",c,w,value,gold[c*4096+w]);
      end
      access(1,32'h70000000,4,value);
      if(c%11==10)begin @(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;end
      if(c%25==24)$display("[DB-RANDOM] %0d/%0d",c+1,CASES);
    end
    if(irqs!=CASES||dual==0)$fatal(1,"random coverage missing");
    $display("[DB-RANDOM] PASS backend=%0d lanes=%0d cases=%0d full16KB compare IRQs=%0d dual=%0d",MEM_BACKEND,LANES,CASES,irqs,dual);$finish;
  end
  initial begin #1000000000;$fatal(1,"random timeout");end
endmodule
