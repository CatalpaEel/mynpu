`timescale 1ns/1ps
module tb_cpu_rf;
  logic clk=0,rst_n=0,scan_cg_en_i=0;
  always #5 clk=~clk;
  logic [5:0] raddr_a_i=0,raddr_b_i=0,raddr_c_i=0,waddr_a_i=0,waddr_b_i=0;
  logic [31:0] wdata_a_i=0,wdata_b_i=0,rdata_a_o,rdata_b_o,rdata_c_o,ra,rb,rc;
  logic we_a_i=0,we_b_i=0;
  int checks=0;
  cv32e40p_register_file #(.ADDR_WIDTH(6)) dut(.*);
  reference_register_file #(.ADDR_WIDTH(6)) reference_dut(
    .rdata_a_o(ra),.rdata_b_o(rb),.rdata_c_o(rc),.*);
  task automatic compare;
    if({rdata_a_o,rdata_b_o,rdata_c_o}!=={ra,rb,rc})
      $fatal(1,"CPU RF mismatch check=%0d addrs=%h/%h/%h",checks,raddr_a_i,raddr_b_i,raddr_c_i);
    checks++;
  endtask
  initial begin
    repeat(3) @(negedge clk);
    for(int n=0;n<20000;n++) begin
      @(negedge clk);
      rst_n=n%233!=0;
      scan_cg_en_i=1'($urandom);
      waddr_a_i=6'($urandom);waddr_b_i=6'($urandom);
      wdata_a_i=$urandom;wdata_b_i=$urandom;
      we_a_i=1'($urandom);we_b_i=1'($urandom);
      if(n%4==0) begin waddr_b_i=waddr_a_i;we_a_i=1;we_b_i=1;end
      if(n%31==0) begin waddr_a_i=0;waddr_b_i=0;end
      raddr_a_i=waddr_a_i;raddr_b_i=waddr_b_i;raddr_c_i=6'($urandom);
      #1;compare();
      @(posedge clk);#1;compare();
    end
    $display("CPU_RF_PROTO PASS checks=%0d cycles=20000",checks);
    $finish;
  end
  initial begin #1000000;$fatal(1,"CPU RF probe timeout");end
endmodule
