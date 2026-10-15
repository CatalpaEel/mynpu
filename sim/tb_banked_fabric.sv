`timescale 1ns/1ps
module tb_banked_fabric #(parameter MEM_BACKEND=1);
  logic clk=0,rst=0;logic[2:0] req=0,we=0,gnt,rv,exp_rv=0,exp_we=0;
  logic[13:0] addr[0:2];logic[3:0] be[0:2];
  logic[31:0] wd[0:2],rd[0:2],exp_data[0:2],gold[0:4095];
  integer waited[0:2],accepted[0:2];integer dual=0,checks=0;
  always #5 clk=~clk;
  mynpu_banked_sram #(.MEM_BACKEND(MEM_BACKEND)) dut(
    .clk_i(clk),.rst_ni(rst),.req_i(req),.we_i(we),.addr_i(addr),.be_i(be),
    .wdata_i(wd),.gnt_o(gnt),.rvalid_o(rv),.rdata_o(rd));
  always @(posedge clk)begin
    if(!rst)begin exp_rv=0;for(integer p=0;p<3;p++)waited[p]=0;end
    else begin
      if(rv!==exp_rv)$fatal(1,"response owner/loss rv=%b exp=%b",rv,exp_rv);
      for(integer p=0;p<3;p++)begin
        if(exp_rv[p]&&!exp_we[p])begin
          if(rd[p]!==exp_data[p])$fatal(1,"fabric read port=%0d hw=%h ref=%h",p,rd[p],exp_data[p]);checks++;
        end
        accepted[p]=gnt[p];
        if(req[p]&&!gnt[p])waited[p]++;else waited[p]=0;
        if(waited[p]>3)$fatal(1,"port starvation %0d",p);
      end
      if(&dut.bank_req)dual++;
      exp_rv=gnt;exp_we=we;
      for(integer p=0;p<3;p++)if(gnt[p])begin
        exp_data[p]=gold[addr[p]>>2];
        if(we[p])for(integer b=0;b<4;b++)if(be[p][b])gold[addr[p]>>2][b*8+:8]=wd[p][b*8+:8];
      end
    end
  end
  initial begin
    for(integer p=0;p<3;p++)begin addr[p]=0;be[p]=15;wd[p]=0;end
    repeat(4)@(negedge clk);rst=1;
    for(integer w=0;w<4096;w++)begin
      req=1;we=1;addr[0]=w*4;wd[0]=32'h12340000^w;
      @(negedge clk);
    end
    req=0;we=0;repeat(3)@(negedge clk);
    for(integer t=0;t<20000;t++)begin
      for(integer p=0;p<3;p++)if(!req[p]||accepted[p])begin
        req[p]=($urandom_range(0,99)<85);we[p]=$urandom_range(0,1);
        addr[p]=$urandom_range(0,4095)*4;be[p]=$urandom_range(0,15);wd[p]=$urandom;
        // Sustained same-bank conflicts plus repeated identical-row hazards.
        if(t%4==0)addr[p]=14'h0400;
      end
      @(negedge clk);
      if(t%2000==1999)begin
        rst=0;req=0;repeat(3)@(negedge clk);rst=1;
      end
    end
    req=0;we=0;repeat(3)@(negedge clk);
    for(integer w=0;w<4096;w++)begin
      req=1;addr[0]=w*4;@(negedge clk);
    end
    req=0;repeat(3)@(negedge clk);
    if(dual==0||checks<10000)$fatal(1,"fabric coverage missing");
    $display("[DB-FABRIC] PASS backend=%0d cycles=20000 checks=%0d dual=%0d masks/conflicts/reset/preservation",MEM_BACKEND,checks,dual);$finish;
  end
endmodule
