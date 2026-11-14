`timescale 1ns/1ps
module tb_gpio;
  logic clk=0, rst_n=0, tck=0, tms=1, tdi=0;
  always #10 clk=~clk;
  wire tdo;
  wire [7:0] gpio_in,gpio_out,gpio_oe;
  tri [7:0] pins;
  logic [7:0] external_oe=0,external_data=0;
  for(genvar b=0;b<8;b++) begin:g_pin
    assign pins[b]=external_oe[b] ? external_data[b] : 1'bz;
    PDDW0204CDG pad(.I(gpio_out[b]),.OEN(~gpio_oe[b]),.PAD(pins[b]),
      .C(gpio_in[b]),.IE(1'b1),.PE(1'b0),.DS(1'b0));
  end
  npu_soc dut(
    .clk_i(clk),.rst_ni(rst_n),.cpu_run_i(1'b1),
    .gpio_i(gpio_in),.gpio_o(gpio_out),.gpio_oe_o(gpio_oe),
    .tck_i(tck),.tms_i(tms),.td_i(tdi),.td_o(tdo),.cpu_debug_halted_o(),
    .irq_o(),.cpu_test_done_o(),.cpu_test_pass_o());
  `include "db_jtag_tasks.svh"
  `include "db_sba_access.svh"
  localparam logic [31:0] BASE=32'h40000800;
  int checks=0;
  task automatic eq(input logic[31:0]got,want,input string what);
    if(got!==want)$fatal(1,"%s got=%h expected=%h",what,got,want);
    checks++;
  endtask
  task automatic bus(input bit we,input logic[31:0] addr,data,
                     output logic[31:0] result,input bit error_expected=0,input logic[3:0] be=15);
    sba_access(we, addr, data, be, error_expected, result);
    checks++;
  endtask
  task automatic wr(input logic[7:0] offset,input logic[31:0]value,input bit err=0);
    logic[31:0] unused;bus(1,BASE+offset,value,unused,err);
  endtask
  task automatic rd(input logic[7:0] offset,input logic[31:0]value);
    logic[31:0] result;bus(0,BASE+offset,0,result);eq(result,value,"read register");
  endtask
  logic [31:0] v;
  logic [40:0] scan;
  bit discard;
  initial begin
    #100;rst_n=1;repeat(12)@(negedge clk);
    eq(gpio_oe,0,"reset DIR");eq(gpio_out,0,"reset OUT");
    if(pins!==8'hzz)$fatal(1,"pins must reset high impedance");checks++;
    rd('h18,32'h00010008);
    external_oe='hff;external_data='ha5;repeat(4)@(negedge clk);rd(0,'ha5);
    wr(4,32'h1234565a);rd(4,'h5a);eq(pins,'ha5,"OUT preload does not drive inputs");
    external_oe='hf0;external_data='hc0;wr(8,'h0f);eq(pins,'hca,"mixed direction");
    rd(8,'h0f);rd(0,'hca);
    wr('h0c,32'hffff0005);rd(4,'h5f);eq(pins,'hcf,"set mask");
    wr('h10,3);rd(4,'h5c);eq(pins,'hcc,"clear mask");
    wr('h14,12);rd(4,'h50);eq(pins,'hc0,"toggle mask");
    wr(0,255,1);wr('h18,0,1);wr('h1c,255,1);rd(4,'h50);rd(8,'h0f);
    bus(1,BASE+8,255,v,1,1);rd(8,'h0f); // Existing bus requires full-word MMIO writes.
    bus(1,BASE+9,255,v,1);rd(8,'h0f);
    external_oe=0;wr(4,'h96);wr(8,'hff);eq(pins,'h96,"all eight outputs");rd(0,'h96);
    rst_n=0;#1;eq(gpio_oe,0,"POR output release");
    if(pins!==8'hzz)$fatal(1,"POR pins not released");checks++;
    #100;rst_n=1;repeat(12)@(negedge clk);rd(4,0);rd(8,0);
    // Exercise the actual external JTAG TAP and SBA, not an internal DMI force.
    repeat(8)tick(1,0,discard);tick(0,0,discard);select_ir(1);scan_dr(32,0,scan);
    eq(scan[31:0],1,"JTAG IDCODE");select_ir('h11);dmi_write('h10,1);
    sba_write(BASE+4,'ha6);sba_write(BASE+8,'hff);eq(pins,'ha6,"SBA output");
    sba_read(BASE,v);eq(v,'ha6,"SBA input readback");
    // A single physical TAP serializes commands; test atomic SET composition.
    wr(4,0);
    sba_write(BASE+'h0c,1);
    sba_write(BASE+'h0c,'h80);
    rd(4,'h81);eq(pins,'h81,"SBA atomic SET composition");
    sba_write(BASE+8,0);if(pins!==8'hzz)$fatal(1,"SBA high impedance");checks++;
    external_oe=255;external_data='h3c;idle_ticks(8);sba_read(BASE,v);eq(v,'h3c,"SBA external input");
    dmi_write('h10,3);dmi_write('h10,1);idle_ticks(16);
    sba_read(BASE+4,v);eq(v,0,"ndmreset OUT");sba_read(BASE+8,v);eq(v,0,"ndmreset DIR");
    // Real RV32 program: OUT=0x3c; DIR=0xff; then loop. No bus shortcut.
    external_oe=0;
    bus(1,32'h80000080,32'h400012b7,v); // lui x5,0x40001
    bus(1,32'h80000084,32'h03c00313,v); // addi x6,x0,0x3c
    bus(1,32'h80000088,32'h8062a223,v); // sw x6,-2044(x5): GPIO_OUT
    bus(1,32'h8000008c,32'h0ff00313,v); // addi x6,x0,0xff
    bus(1,32'h80000090,32'h8062a423,v); // sw x6,-2040(x5): GPIO_DIR
    bus(1,32'h80000094,32'h0000006f,v); // jal x0,0
    bus(1,32'h40000008,1,v);
    for(int j=0;j<500;j++)begin @(negedge clk);if(gpio_oe==255)break;end
    eq(gpio_oe,255,"CPU DIR write");eq(pins,'h3c,"CPU byte output");rd(0,'h3c);
    bus(1,32'h40000008,0,v);
    repeat(10)@(negedge clk);
    eq(gpio_oe,255,"CPU-only reset retains GPIO direction");
    eq(pins,'h3c,"CPU-only reset retains GPIO output");
    $display("GPIO PASS checks=%0d CPU, JTAG SBA, actual PAD, direction, masks, resets",checks);
    $finish;
  end
  initial begin #20000000000;$fatal(1,"GPIO global timeout");end
endmodule
