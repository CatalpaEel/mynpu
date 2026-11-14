`timescale 1ns/1ps
// Test the actual ASIC shell/mapped netlist with native bidirectional PADs.
module tb_gpio_chip;
  logic clk=0,rst_n=0,tck=0,tms=1,tdi=0;
  always #10 clk=~clk;
  wire tdo;
  tri [7:0] pins;
  logic [7:0] external_oe=0,external_data=0;
  for(genvar b=0;b<8;b++)assign pins[b]=external_oe[b]?external_data[b]:1'bz;
  mynpu_asic_top dut(.clk_i(clk),.rst_ni(rst_n),.boot_ready_i(1'b1),
    .tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),.npu_irq_o(),
    .cpu_debug_halted_o(),.gpio_io(pins));
  `include "db_jtag_tasks.svh"
  localparam logic[31:0] BASE=32'h40000800;
  int checks=0;
  task automatic eq(input logic[31:0]got,want,input string label);
    if(got!==want)$fatal(1,"%s got=%h expected=%h",label,got,want);
    checks++;
  endtask
  logic[31:0] v;
  logic[40:0] scan;
  bit discard;
  initial begin
    #100;rst_n=1;repeat(12)@(negedge clk);
    if(pins!==8'hzz)$fatal(1,"PADs not high impedance on POR");checks++;
    external_oe=255;external_data='ha5;
    repeat(8)tick(1,0,discard);tick(0,0,discard);select_ir(1);scan_dr(32,0,scan);
    eq(scan[31:0],1,"IDCODE");select_ir('h11);dmi_write('h10,1);
    sba_read(BASE+'h18,v);eq(v,'h00010008,"GPIO capability");
    sba_read(BASE,v);eq(v,'ha5,"external input byte");
    sba_write(BASE+4,'h5a);eq(pins,'ha5,"OUT preloaded with no output enable");
    external_oe='hf0;external_data='hc0;
    sba_write(BASE+8,'h0f);eq(pins,'hca,"mixed PAD direction");
    sba_read(BASE,v);eq(v,'hca,"mixed input readback");
    external_oe=0;sba_write(BASE+8,255);
    for(int b=0;b<8;b++)begin
      sba_write(BASE+4,1<<b);eq(pins,1<<b,"walking output bit order");
      sba_read(BASE,v);eq(v,1<<b,"walking output readback");
    end
    sba_write(BASE+8,0);if(pins!==8'hzz)$fatal(1,"DIR=0 not high impedance");checks++;
    external_oe=255;
    for(int b=0;b<8;b++)begin
      external_data=1<<b;idle_ticks(8);sba_read(BASE,v);eq(v,1<<b,"walking external input");
    end
    dmi_write('h10,3);dmi_write('h10,1);idle_ticks(16);
    sba_read(BASE+4,v);eq(v,0,"ndmreset OUT");sba_read(BASE+8,v);eq(v,0,"ndmreset DIR");
    // CPU, not the debugger, performs these GPIO writes after bootstrap release.
    external_oe=0;
    sba_write(32'h80000080,32'h400012b7);sba_write(32'h80000084,32'h03c00313);
    sba_write(32'h80000088,32'h8062a223);sba_write(32'h8000008c,32'h0ff00313);
    sba_write(32'h80000090,32'h8062a423);sba_write(32'h80000094,32'h0000006f);
    sba_write(32'h40000008,1);idle_ticks(64);
    eq(pins,'h3c,"CPU GPIO byte through native PADs");sba_read(BASE,v);eq(v,'h3c,"CPU output readback");
    $display("GPIO CHIP PASS checks=%0d real PAD, bit order, JTAG SBA, CPU",checks);
    $finish;
  end
  initial begin #20000000;$fatal(1,"GPIO chip timeout");end
endmodule
