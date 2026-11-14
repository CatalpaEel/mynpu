`timescale 1ns/1ps
// Real CPU fetch/data + Vector traffic, with all external accesses through TAP.
module tb_jtag_running;
  logic clk=0, rst_n=0, tck=0, tms=1, tdi=0;
  always #10 clk=~clk;
  wire tdo, halted;
  npu_soc dut(.clk_i(clk),.rst_ni(rst_n),.cpu_run_i(1'b1),
    .tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),
    .cpu_debug_halted_o(halted),
    .irq_o(),.cpu_test_done_o(),.cpu_test_pass_o());
  `include "db_jtag_tasks.svh"
  `include "db_sba_access.svh"
  int checks=0, grants=0, replies=0, overlapping_grants=0, vector_grants=0;
  int fetch_grants=0, data_grants=0, outstanding=0, max_wait=0, waiting=0;
  bit running=0, running_size_error;
  logic [31:0] random_state=32'h67ba1203, v, before_count, after_count, address, value;
  always @(posedge clk) if (rst_n) begin
    if (running && halted) $fatal(1,"CPU was halted during running SBA stress");
    if (dut.i_core.req[3] && !dut.i_core.gnt[3]) waiting++;
    if (dut.i_core.req[3] && dut.i_core.gnt[3]) begin
      grants++;
      if(waiting>max_wait)max_wait=waiting;
      waiting=0;
      if (running && (dut.i_core.req[0] || dut.i_core.req[4] || dut.i_core.req[2]))
        overlapping_grants++;
    end
    if(dut.i_core.rvalid[3])replies++;
    outstanding += int'(dut.i_core.req[3] && dut.i_core.gnt[3]) - int'(dut.i_core.rvalid[3]);
    if(outstanding<0 || outstanding>1)$fatal(1,"SBA response accounting %0d",outstanding);
    if(running)begin
      if(dut.i_core.req[4] && dut.i_core.gnt[4])fetch_grants++;
      if(dut.i_core.req[0] && dut.i_core.gnt[0])data_grants++;
      if(dut.i_core.req[2] && dut.i_core.gnt[2])vector_grants++;
    end
  end
  task automatic wr(input logic[31:0]a,d);
    logic[31:0]unused;sba_access(1,a,d,15,0,unused);
  endtask
  task automatic rd(input logic[31:0]a,output logic[31:0]d);
    sba_access(0,a,0,15,0,d);
  endtask
  task automatic eq(input logic[31:0]got,want);
    if(got!==want)$fatal(1,"running SBA got=%h want=%h",got,want);
    checks++;
  endtask
  initial begin
    #100;rst_n=1;
    // CPU repeatedly updates both SRAM banks and starts Vector when idle.
    wr(32'h80000080, 32'h800022b7); // 0
    wr(32'h80000084, 32'h80028293); // 1
    wr(32'h80000088, 32'h800043b7); // 2
    wr(32'h8000008c, 32'h80038393); // 3
    wr(32'h80000090, 32'h400004b7); // 4
    wr(32'h80000094, 32'h20048493); // 5
    wr(32'h80000098, 32'h00000313); // 6
    wr(32'h8000009c, 32'h00130313); // 7
    wr(32'h800000a0, 32'h0062a023); // 8
    wr(32'h800000a4, 32'h0003a403); // 9
    wr(32'h800000a8, 32'h0063a023); // 10
    wr(32'h800000ac, 32'h0044a503); // 11
    wr(32'h800000b0, 32'h00157513); // 12
    wr(32'h800000b4, 32'hfe0514e3); // 13
    wr(32'h800000b8, 32'h00100513); // 14
    wr(32'h800000bc, 32'h00a4a023); // 15
    wr(32'h800000c0, 32'hfddff06f); // 16
    for(int i=0;i<64;i++)wr(32'h80002000+4*i,32'(i));
    wr('h40000208,'h80002000);wr('h40000218,0);
    wr('h4000020c,'h80002400);wr('h40000210,64);
    wr('h40000214,'h81);wr('h40000230,1); // INT32 ADD scalar 1
    wr('h80001800,0);wr('h80003800,0);
    wr('h4000000c,'h80000080);wr('h40000008,1);
    running=1;
    rd('h80001800,before_count);
    for(int i=0;i<1024;i++)begin
      random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
      address=(random_state[0] ? 32'h80003000 : 32'h80001000) + {24'b0,random_state[6:1],2'b0};
      value=random_state ^ 32'(i);
      wr(address,value);rd(address,v);eq(v,value);
      if(i%8==0)begin rd('h40000050,v);eq(v,32'h00020020);end
    end
    rd('h80001800,after_count);
    if(after_count<=before_count)$fatal(1,"CPU made no forward progress");
    rd('h80003800,v);if(v==0)$fatal(1,"CPU bank1 store missing");checks++;
    rd('h800024fc,v);eq(v,64); // last Vector element: 63 + 1
    // Rejected MMIO, unaligned access, and unsupported size must report/clear errors.
    sba_access(1,'h40000300,1,15,1,v);checks++;
    sba_access(0,'h80001001,0,15,1,v);checks++;
    sba_one(0,'h80001000,0,3,v,running_size_error);
    if(!running_size_error)$fatal(1,"unsupported size not rejected");checks++;
    rd('h40000050,v);eq(v,'h00020020);
    // Lane placement and narrow reads through genuine SBA.
    wr('h80001200,'h11223344);
    sba_access(1,'h80001200,'haa0000,4'b0100,0,v);
    rd('h80001200,v);eq(v,'h11aa3344);
    sba_one(0,'h80001202,0,1,v,running_size_error);eq(v,'h11aa);
    if(running_size_error)$fatal(1,"halfword read failed");
    running=0;
    dmi_write('h10,3);dmi_write('h10,1);idle_ticks(16);
    rd('h80001200,v);eq(v,'h11aa3344);
    if(grants!=replies || outstanding!=0)$fatal(1,"SBA lost/duplicate response");
    if(overlapping_grants<100 || vector_grants<100 || fetch_grants<1000 || data_grants<1000)
      $fatal(1,"insufficient CPU/NPU contention");
    $display("JTAG RUNNING PASS checks=%0d grants=%0d replies=%0d overlap=%0d fetch=%0d data=%0d vector=%0d max_wait=%0d",checks,grants,replies,overlapping_grants,fetch_grants,data_grants,vector_grants,max_wait);
    $finish;
  end
  initial begin #10000000000;$fatal(1,"running JTAG timeout");end
endmodule
