`timescale 1ns/1ps

// Standalone check for the real single-port SRAM schedule.  The word-packed
// image is loaded into the FPGA BRAM model; the same test can be compiled with
// the foundry .v model and MEM_BACKEND=2 in an ASIC simulation.
module tb_cnn_npu_sp #(
  parameter integer RUNS = 5,
  parameter bit STRESS_MODE = 1'b1
);
  localparam integer LOCAL_BASE=14'h1000;
  localparam integer DESC_BASE=7168;
  localparam integer OUTPUT_BASE=5120;
  localparam integer INPUT_BYTES=784;
  logic clk=0, rst_ni=0, ena=0, wea=0;
  logic [3:0] be=4'hf;
  logic [13:0] addra=0;
  logic [31:0] dina=0, douta;
  logic irq;
  integer polls, i, run, word_addr, byte_lane, got, expected, errors;
  logic [31:0] value, status;
  logic [7:0] input_image [0:INPUT_BYTES-1];
  always #5 clk=~clk;
  initial $readmemh("cnn_npu_int8/generated/8k/input_codes.hex",input_image);

  cnn_npu_sp_top #(
    .LANES(1), .SRAM_BYTES(8192), .MAX_LAYERS(8), .MEM_BACKEND(1),
    .MEM_INIT_FILE("cnn_npu_int8/generated/8k/npu_word.hex")
  ) dut (.clka(clk),.rst_ni(rst_ni),.ena(ena),.wea(wea),.be_i(be),
         .addra(addra),.dina(dina),.douta(douta),.irq_o(irq));

  task automatic bus_write(input integer a, input logic [31:0] d);
    @(negedge clk); ena=1; wea=1; addra=a; dina=d;
    @(posedge clk); @(negedge clk); ena=0; wea=0; addra=0; dina=0;
  endtask
  task automatic bus_read(input integer a, output logic [31:0] d);
    @(negedge clk); ena=1; wea=0; addra=a;
    @(posedge clk); @(negedge clk); @(posedge clk); #1 d=douta;
    @(negedge clk); ena=0; addra=0;
  endtask
  task automatic reload_input;
    integer w, b; logic [31:0] word_data;
    begin
      for (w=0; w<INPUT_BYTES/4; w=w+1) begin
        word_data=0;
        for (b=0;b<4;b=b+1) word_data[b*8 +: 8]=input_image[w*4+b];
        bus_write(LOCAL_BASE + OUTPUT_BASE/4 + w, word_data);
      end
    end
  endtask

  initial begin
    repeat(4) @(posedge clk); rst_ni=1; repeat(2) @(posedge clk);
    bus_write(4, DESC_BASE); bus_write(5, 6);
    if (STRESS_MODE) begin
      // Invalid layer count and descriptor base must enter ERROR and recover
      // after the documented control clear, without wrapping the SRAM port.
      bus_write(5, 255); bus_write(0, 1);
      status=0;
      for (i=0; i<100; i=i+1) begin
        bus_read(1,status);
      end
      if (!status[2]) $fatal(1,"single-port invalid layer count did not error");
      bus_write(0, 4); bus_read(1,status);
      if (status[2]) $fatal(1,"single-port layer-count error did not clear");

      bus_write(5, 6); bus_write(4, 8190); bus_write(0, 1);
      status=0;
      for (i=0; i<100; i=i+1) begin
        bus_read(1,status);
      end
      if (!status[2]) $fatal(1,"single-port invalid descriptor base did not error");
      bus_write(0, 4); bus_read(1,status);
      if (status[2]) $fatal(1,"single-port descriptor error did not clear");
      bus_write(4, DESC_BASE);
      $display("[CNN-SP-STRESS] invalid layer/descriptor inputs rejected and cleared");
    end
    errors=0; polls=0;
    for (run=0; run<RUNS; run=run+1) begin
      if (run>0) reload_input;
      bus_write(0, 1); status=0;
      while (!(status[1]) && polls<2000000*RUNS) begin bus_read(1,status); polls=polls+1; end
      if (!status[1]) $fatal(1,"single-port NPU timeout run=%0d status=%h polls=%0d",run,status,polls);
      for(i=0;i<10;i=i+1) begin
      word_addr=LOCAL_BASE+(OUTPUT_BASE+i)/4; byte_lane=(OUTPUT_BASE+i)%4;
      case(i)
        0: expected=68; 1: expected=50; 2: expected=82; 3: expected=68;
        4: expected=55; 5: expected=80; 6: expected=75; 7: expected=63;
        8: expected=76; 9: expected=59;
      endcase
      bus_read(word_addr,value); got=(value>>(byte_lane*8))&255;
      if (got !== expected) begin
        $display("[CNN-SP] output[%0d] hw=%0d expected=%0d",i,got,expected);
        errors=errors+1;
      end
      end
      bus_write(0, 4);
    end
    if(errors) $fatal(1,"single-port NPU output errors=%0d",errors);
    $display("[CNN-SP] PASS %0d repeated runs, single-port FPGA SRAM schedule polls=%0d cycles=%0d",RUNS,polls,dut.cycle_q);
    $finish;
  end
endmodule
