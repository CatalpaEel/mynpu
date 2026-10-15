`timescale 1ns/1ps
module tb_npu_banked_edges #(parameter MEM_BACKEND=1,LANES=4,ACT_CACHE_WORDS=1);
  logic clk=0,rst=0,req=0,we=0,gnt,rv,err,irq,hw;
  logic[31:0]addr=0,wd=0,rd,ha,hwd,value,status;logic[3:0]be=15,hbe;
  always #5 clk=~clk;
  mynpu_shared_subsystem #(.LANES(LANES),.MEM_BACKEND(MEM_BACKEND),.ACT_CACHE_WORDS(ACT_CACHE_WORDS))dut(
    .clk_i(clk),.rst_ni(rst),.req_i(req),.we_i(we),.addr_i(addr),.wdata_i(wd),.be_i(be),
    .gnt_o(gnt),.rvalid_o(rv),.error_o(err),.rdata_o(rd),.irq_o(irq),
    .host_write_o(hw),.host_addr_o(ha),.host_wdata_o(hwd),.host_be_o(hbe));
  task automatic access(input bit wr,input logic[31:0]a,d,output logic[31:0]result);
    @(negedge clk);req=1;we=wr;addr=a;wd=d;do @(posedge clk);while(!gnt);
    @(negedge clk);req=0;we=0;while(!rv)@(negedge clk);
    result=rd;if(err)$fatal(1,"unexpected address error");@(negedge clk);
  endtask
  task automatic setup;
    access(1,'h70004000,8192,value);access(1,'h70004004,12288,value);
    access(1,'h70004008,1024,value);access(1,'h7000400c,1088,value);
    access(1,'h70004010,1120,value);access(1,'h70004014,1152,value);
    access(1,'h70004018,'h04040101,value);access(1,'h7000401c,'h05010101,value);
    access(1,'h70004020,'h007f0000,value);
    access(1,'h70006000,'h04030201,value);
    for(integer i=0;i<4;i++)begin
      access(1,'h70004400+i*4,'h01010101,value);
      access(1,'h70004440+i*4,0,value);access(1,'h70004460+i*4,1,value);
    end
    access(1,'h70004480,0,value);access(1,'h70000010,0,value);access(1,'h70000014,1,value);
  endtask
  task automatic finish_ok;
    for(integer i=0;i<1000;i++)begin access(0,'h70000004,0,status);if(status[1]||status[2])break;end
    if((status&7)!=2||!irq)$fatal(1,"expected DONE, status=%h",status);
    access(0,'h70007000,0,value);if(value!=='h0a0a0a0a)$fatal(1,"FC result=%h",value);
    access(1,'h70000000,4,value);if(irq)$fatal(1,"IRQ failed to clear");
  endtask
  initial begin
    repeat(4)@(negedge clk);rst=1;setup();
    // Byte enable zero is a genuine no-op, including START/CLEAR commands.
    be=0;access(1,'h70000000,3,value);be=15;
    access(0,'h70000004,0,status);if(status!=0)$fatal(1,"zero-byte START changed state");
    for(integer c=0;c<6;c++)begin
      case(c)
        0:access(1,'h70000010,16380,value); // descriptor spans macro-space boundary
        1:access(1,'h70000014,9,value); // layer count exceeds MAX
        2:access(1,'h70004008,16380,value); // weights out of range
        3:access(1,'h70004480,64,value); // invalid shift
        4:access(1,'h7000401c,'h0d010101,value); // unsupported replicated-weight flag
        5:access(1,'h70000010,1,value); // unaligned descriptor
      endcase
      access(1,'h70000000,3,value);
      for(integer i=0;i<1000;i++)begin access(0,'h70000004,0,status);if(status[2])break;end
      if((status&5)!=4||!irq)$fatal(1,"invalid config did not fail safely case=%0d status=%h",c,status);
      setup();access(1,'h70000000,7,value);finish_ok(); // ERROR -> CLEAR+START
    end
    for(integer run=0;run<20;run++)begin
      access(1,'h70000000,3,value);access(1,'h70000000,3,value); // BUSY start must not queue
      finish_ok();repeat(20)@(negedge clk);
      if(irq||dut.busy)$fatal(1,"busy START was queued");
      if(run%5==4)begin rst=0;repeat(3)@(negedge clk);rst=1;setup();end
    end
    $display("[DB-EDGES] PASS backend=%0d lanes=%0d cache=%0d invalid descriptor/shift/flags + ERROR recovery + BUSY START + byte masks + resets",MEM_BACKEND,LANES,ACT_CACHE_WORDS);$finish;
  end
  initial begin #10000000;$fatal(1,"edges timeout");end
endmodule
