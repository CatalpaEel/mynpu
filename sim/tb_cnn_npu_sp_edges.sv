`timescale 1ns/1ps

// Quantization and storage-boundary regression for the physical single-port
// schedule.  The test writes every descriptor/parameter byte through the same
// bus used by the SoC, then exercises signed weight/activation extremes,
// shift=0/63, ReLU, qmax and odd FC channel count.
module tb_cnn_npu_sp_edges #(
  parameter integer MEM_BACKEND = 1,
  parameter MEM_INIT_FILE = ""
);
  localparam integer LOCAL_BASE = 14'h1000;
  localparam integer IN_BASE = 128;
  localparam integer OUT_BASE = 256;
  localparam integer WEIGHT_BASE = 512;
  localparam integer BIAS_BASE = 600;
  localparam integer MULT_BASE = 620;
  localparam integer SHIFT_BASE = 640;
  localparam logic [31:0] BUSY_ERROR = 32'hdead_b001;

  logic clk=0, rst_ni=0, ena=0, wea=0;
  logic [3:0] be=4'hf;
  logic [13:0] addra=0;
  logic [31:0] dina=0, douta;
  logic irq;
  logic [31:0] status, value;
  integer errors, irq_edges;

  always #5 clk=~clk;
  always @(posedge irq) irq_edges++;

  cnn_npu_sp_top #(
    .LANES(1), .SRAM_BYTES(8192), .MAX_LAYERS(8),
    .MEM_BACKEND(MEM_BACKEND), .MEM_INIT_FILE(MEM_INIT_FILE)
  ) dut (
    .clka(clk), .rst_ni(rst_ni), .ena(ena), .wea(wea), .be_i(be),
    .addra(addra), .dina(dina), .douta(douta), .irq_o(irq)
  );

  task automatic bus_write_be(input integer a, input logic [31:0] d,
                              input logic [3:0] m);
    @(negedge clk); ena=1; wea=1; addra=a; dina=d; be=m;
    @(posedge clk); @(negedge clk);
    ena=0; wea=0; addra=0; dina=0; be=4'hf;
  endtask
  task automatic bus_write(input integer a, input logic [31:0] d);
    bus_write_be(a,d,4'hf);
  endtask
  task automatic bus_read(input integer a, output logic [31:0] d);
    @(negedge clk); ena=1; wea=0; addra=a;
    @(posedge clk); @(negedge clk); @(posedge clk); #1 d=douta;
    @(negedge clk); ena=0; addra=0;
  endtask
  task automatic write_byte(input integer byte_addr, input logic [7:0] d);
    integer lane;
    lane=byte_addr & 3;
    bus_write_be(LOCAL_BASE + (byte_addr>>2),
                 ({24'd0,d} << (lane*8)), 4'b0001 << lane);
  endtask
  task automatic write_signed_byte(input integer byte_addr, input integer d);
    write_byte(byte_addr, d[7:0]);
  endtask
  task automatic read_output(input integer idx, output integer d);
    integer lane;
    lane=(OUT_BASE+idx) & 3;
    bus_read(LOCAL_BASE + ((OUT_BASE+idx)>>2),value);
    d=(value >> (lane*8)) & 8'hff;
  endtask
  task automatic clear_memory_words;
    for (integer k=0;k<4;k++) bus_write(LOCAL_BASE + k,32'd0);
  endtask
  task automatic program_descriptor(input logic [7:0] flags,
                                    input logic [7:0] input_zp,
                                    input logic [7:0] output_zp,
                                    input logic [7:0] qmax);
    bus_write(LOCAL_BASE + 0,IN_BASE);
    bus_write(LOCAL_BASE + 1,OUT_BASE);
    bus_write(LOCAL_BASE + 2,WEIGHT_BASE);
    bus_write(LOCAL_BASE + 3,BIAS_BASE);
    bus_write(LOCAL_BASE + 4,MULT_BASE);
    bus_write(LOCAL_BASE + 5,SHIFT_BASE);
    bus_write(LOCAL_BASE + 6,32'h03030101); // ih=iw=1, ic=3, oc=3
    bus_write(LOCAL_BASE + 7,{flags,8'd1,8'd1,8'd1});
    bus_write(LOCAL_BASE + 8,{8'd0,qmax,output_zp,input_zp});
    bus_write(5,32'd1);
    bus_write(4,32'd0);
  endtask
  task automatic program_common_weights(input logic signed [7:0] w0,
                                        input logic signed [7:0] w1,
                                        input logic signed [7:0] w2);
    write_signed_byte(WEIGHT_BASE+0,w0); write_signed_byte(WEIGHT_BASE+1,w1); write_signed_byte(WEIGHT_BASE+2,w2);
    write_signed_byte(WEIGHT_BASE+3,w0); write_signed_byte(WEIGHT_BASE+4,w1); write_signed_byte(WEIGHT_BASE+5,w2);
    write_signed_byte(WEIGHT_BASE+6,w0); write_signed_byte(WEIGHT_BASE+7,w1); write_signed_byte(WEIGHT_BASE+8,w2);
    for (integer k=0;k<3;k++) bus_write(BIAS_BASE/4 + LOCAL_BASE + k,32'd0);
    for (integer k=0;k<3;k++) bus_write(MULT_BASE/4 + LOCAL_BASE + k,32'd1);
    write_byte(SHIFT_BASE+0,8'd0); write_byte(SHIFT_BASE+1,8'd0); write_byte(SHIFT_BASE+2,8'd0);
    write_byte(IN_BASE+0,8'd0); write_byte(IN_BASE+1,8'd127); write_byte(IN_BASE+2,8'd255);
  endtask
  task automatic run_and_check(input integer e0, input integer e1, input integer e2);
    integer got;
    bus_write(0,32'd1); status=0;
    for (integer k=0;k<10000;k++) begin
      bus_read(1,status);
      if (status[1] || status[2]) break;
    end
    if (!status[1] || status[2]) $fatal(1,"edge case failed status=%h",status);
    read_output(0,got); if (got!==e0) begin $display("edge out0=%0d ref=%0d",got,e0); errors++; end
    read_output(1,got); if (got!==e1) begin $display("edge out1=%0d ref=%0d",got,e1); errors++; end
    read_output(2,got); if (got!==e2) begin $display("edge out2=%0d ref=%0d",got,e2); errors++; end
    bus_write(0,32'd4);
  endtask
  task automatic invalid_descriptor_tail;
    bus_write(4,32'd8160); // only 32 bytes remain, descriptor needs 36
    bus_write(0,32'd1); status=0;
    for (integer k=0;k<100;k++) begin
      bus_read(1,status);
      if (status[2]) break;
    end
    if (!status[2]) $fatal(1,"descriptor tail overflow was not rejected");
    bus_write(0,32'd4);
  endtask
  task automatic write_descriptor_at(input integer db, input integer ib,
                                     input integer ob, input integer layers);
    for (integer l=0;l<layers;l++) begin
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 0,ib);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 1,ob);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 2,WEIGHT_BASE);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 3,BIAS_BASE);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 4,MULT_BASE);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 5,SHIFT_BASE);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 6,32'h03030101);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 7,32'h01010101);
      bus_write(LOCAL_BASE + ((db + l*36)/4) + 8,32'h00ff0000);
    end
  endtask
  task automatic max_layer_chain;
    integer got;
    // Eight legal FC descriptors, with the output of each layer feeding the
    // next layer. Identity weights make the expected result invariant.
    write_descriptor_at(0,1024,1024,8);
    bus_write(5,32'd8); bus_write(4,32'd0);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE + BIAS_BASE/4 + k,32'd0);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE + MULT_BASE/4 + k,32'd1);
    write_signed_byte(WEIGHT_BASE+0,1); write_signed_byte(WEIGHT_BASE+1,0); write_signed_byte(WEIGHT_BASE+2,0);
    write_signed_byte(WEIGHT_BASE+3,0); write_signed_byte(WEIGHT_BASE+4,1); write_signed_byte(WEIGHT_BASE+5,0);
    write_signed_byte(WEIGHT_BASE+6,0); write_signed_byte(WEIGHT_BASE+7,0); write_signed_byte(WEIGHT_BASE+8,1);
    write_byte(1024,0); write_byte(1025,127); write_byte(1026,255);
    bus_write(0,32'd1); status=0;
    for (integer k=0;k<10000;k++) begin
      bus_read(1,status); if (status[1] || status[2]) break;
    end
    if (!status[1] || status[2]) $fatal(1,"8-layer chain failed status=%h",status);
    for (integer k=0;k<3;k++) begin
      bus_read(LOCAL_BASE + ((1024+k)>>2),value);
      got=(value >> (((1024+k)&3)*8)) & 8'hff;
      if (got !== ((k==0)?0:((k==1)?127:255)))
        $fatal(1,"8-layer output[%0d]=%0d",k,got);
    end
    bus_write(0,32'd4);
  endtask
  task automatic irq_restart_race;
    // One-layer identity model; reuse the already programmed weights.
    integer got;
    program_descriptor(8'h01,8'd0,8'd0,8'd255);
    program_common_weights(8'sd1,8'sd0,8'sd0);
    write_signed_byte(WEIGHT_BASE+3,0); write_signed_byte(WEIGHT_BASE+4,1); write_signed_byte(WEIGHT_BASE+5,0);
    write_signed_byte(WEIGHT_BASE+6,0); write_signed_byte(WEIGHT_BASE+7,0); write_signed_byte(WEIGHT_BASE+8,1);
    irq_edges=0; bus_write(0,32'd4); bus_write(0,32'd3); // START + IRQ enable
    bus_write(0,32'd3); // repeated START while BUSY must be ignored
    status=0;
    for (integer k=0;k<10000;k++) begin
      bus_read(1,status); if (status[1] || status[2]) break;
    end
    if (!status[1] || status[2] || !irq) $fatal(1,"first IRQ race completion failed status=%h irq=%b",status,irq);
    // Restart directly while DONE is still set. The START edge must clear
    // DONE and create exactly one new completion interrupt.
    bus_write(0,32'd3); status=0;
    for (integer k=0;k<10000;k++) begin
      bus_read(1,status); if (status[1] || status[2]) break;
    end
    if (!status[1] || status[2] || irq_edges!==2)
      $fatal(1,"IRQ restart race failed status=%h edges=%0d",status,irq_edges);
    bus_write(0,32'd4);
    if (irq) $fatal(1,"IRQ did not clear after DONE clear");
    read_output(0,got); if (got!==0) $fatal(1,"IRQ race output0=%0d",got);
    $display("[CNN-EDGES] IRQ START/DONE/CLEAR race passed edges=%0d",irq_edges);
  endtask
  task automatic conv_stride1_case;
    integer got;
    bus_write(LOCAL_BASE+0,1024); bus_write(LOCAL_BASE+1,2048);
    bus_write(LOCAL_BASE+2,WEIGHT_BASE); bus_write(LOCAL_BASE+3,BIAS_BASE);
    bus_write(LOCAL_BASE+4,MULT_BASE); bus_write(LOCAL_BASE+5,SHIFT_BASE);
    bus_write(LOCAL_BASE+6,32'h03010303); // 3x3x1 -> 1x1x3
    bus_write(LOCAL_BASE+7,32'h00010101); // stride 1, convolution
    bus_write(LOCAL_BASE+8,32'h00ff0000); bus_write(5,1); bus_write(4,0);
    for (integer k=0;k<9;k++) write_byte(1024+k,k);
    for (integer k=0;k<9;k++) write_signed_byte(WEIGHT_BASE+k,1);
    for (integer k=0;k<9;k++) write_signed_byte(WEIGHT_BASE+9+k,-1);
    for (integer k=0;k<9;k++) write_signed_byte(WEIGHT_BASE+18+k,0);
    write_signed_byte(WEIGHT_BASE+22,1);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE+BIAS_BASE/4+k,0);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE+MULT_BASE/4+k,1);
    for (integer k=0;k<3;k++) write_byte(SHIFT_BASE+k,0);
    bus_write(0,1); status=0;
    for (integer k=0;k<10000;k++) begin bus_read(1,status); if (status[1]||status[2]) break; end
    if (!status[1] || status[2]) $fatal(1,"stride1 convolution failed status=%h",status);
    bus_read(LOCAL_BASE+(2048>>2),value); got=value[7:0]; if (got!==8) $fatal(1,"conv stride1 out0=%0d",got);
    bus_read(LOCAL_BASE+(2048>>2),value); got=value[15:8]; if (got!==0) $fatal(1,"conv stride1 out1=%0d",got);
    bus_read(LOCAL_BASE+(2048>>2),value); got=value[23:16]; if (got!==0) $fatal(1,"conv stride1 out2=%0d",got);
    bus_write(0,4);
  endtask
  task automatic conv_stride2_case;
    integer got;
    bus_write(LOCAL_BASE+0,1024); bus_write(LOCAL_BASE+1,2048);
    bus_write(LOCAL_BASE+2,WEIGHT_BASE); bus_write(LOCAL_BASE+3,BIAS_BASE);
    bus_write(LOCAL_BASE+4,MULT_BASE); bus_write(LOCAL_BASE+5,SHIFT_BASE);
    bus_write(LOCAL_BASE+6,32'h01010303); // 3x3x1 -> 2x2x1
    bus_write(LOCAL_BASE+7,32'h00020202); // stride 2, convolution
    bus_write(LOCAL_BASE+8,32'h00ff0000); bus_write(5,1); bus_write(4,0);
    for (integer k=0;k<9;k++) write_byte(1024+k,k);
    for (integer k=0;k<9;k++) write_signed_byte(WEIGHT_BASE+k,1);
    bus_write(LOCAL_BASE+BIAS_BASE/4,0); bus_write(LOCAL_BASE+MULT_BASE/4,1); write_byte(SHIFT_BASE,0);
    bus_write(0,1); status=0;
    for (integer k=0;k<10000;k++) begin bus_read(1,status); if (status[1]||status[2]) break; end
    if (!status[1] || status[2]) $fatal(1,"stride2 convolution failed status=%h",status);
    bus_read(LOCAL_BASE+(2048>>2),value);
    if (value[7:0]!==8 || value[15:8]!==12 || value[23:16]!==20 || value[31:24]!==24)
      $fatal(1,"conv stride2 outputs=%h",value);
    bus_write(0,4);
  endtask
  task automatic cycle_wrap_case;
    bus_write(LOCAL_BASE+0,128); bus_write(LOCAL_BASE+1,256);
    bus_write(LOCAL_BASE+2,WEIGHT_BASE); bus_write(LOCAL_BASE+3,BIAS_BASE);
    bus_write(LOCAL_BASE+4,MULT_BASE); bus_write(LOCAL_BASE+5,SHIFT_BASE);
    bus_write(LOCAL_BASE+6,32'h03030101); bus_write(LOCAL_BASE+7,32'h01010101);
    bus_write(LOCAL_BASE+8,32'h00ff0000); bus_write(5,1); bus_write(4,0);
    write_byte(128,0); write_byte(129,127); write_byte(130,255);
    for (integer k=0;k<9;k++) write_signed_byte(WEIGHT_BASE+k,0);
    write_signed_byte(WEIGHT_BASE+0,1); write_signed_byte(WEIGHT_BASE+4,1); write_signed_byte(WEIGHT_BASE+8,1);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE+BIAS_BASE/4+k,0);
    for (integer k=0;k<3;k++) bus_write(LOCAL_BASE+MULT_BASE/4+k,1);
    for (integer k=0;k<3;k++) write_byte(SHIFT_BASE+k,0);
    bus_write(0,1); status=0;
    for (integer k=0;k<1000;k++) begin
      bus_read(1,status); if (status[0]) break;
    end
    if (!status[0]) $fatal(1,"cycle-wrap case did not enter BUSY");
    force dut.cycle_q = 32'hfffffff0;
    repeat(4) @(posedge clk);
    release dut.cycle_q;
    for (integer k=0;k<10000;k++) begin
      bus_read(1,status); if (status[1] || status[2]) break;
    end
    if (!status[1] || status[2]) $fatal(1,"cycle-wrap case failed status=%h",status);
    bus_write(0,4);
    $display("[CNN-EDGES] cycle counter wrap recovery passed");
  endtask

  initial begin
    repeat(4) @(posedge clk); rst_ni=1; repeat(2) @(posedge clk);
    errors=0;
    // qmax=255, signed -128/+127 and unsigned activation 0/127/255.
    program_descriptor(8'h01,8'd0,8'd0,8'd255);
    program_common_weights(-8'sd128,8'sd127,8'sd0);
    write_signed_byte(WEIGHT_BASE+0,-8'sd128); write_signed_byte(WEIGHT_BASE+1,-8'sd128); write_signed_byte(WEIGHT_BASE+2,-8'sd128);
    write_signed_byte(WEIGHT_BASE+3,8'sd127);  write_signed_byte(WEIGHT_BASE+4,8'sd127);  write_signed_byte(WEIGHT_BASE+5,8'sd127);
    write_signed_byte(WEIGHT_BASE+6,8'sd0);    write_signed_byte(WEIGHT_BASE+7,8'sd1);    write_signed_byte(WEIGHT_BASE+8,8'sd0);
    run_and_check(0,255,127);

    // shift=63 and qmax=127: the scaled result rounds to zero, then output_zp
    // is applied. This also exercises all three output bytes of an odd FC.
    program_descriptor(8'h01,8'd0,8'd127,8'd127);
    program_common_weights(8'sd127,8'sd127,8'sd127);
    for (integer k=0;k<3;k++) bus_write(MULT_BASE/4 + LOCAL_BASE + k,32'h7fffffff);
    write_byte(SHIFT_BASE+0,8'd63); write_byte(SHIFT_BASE+1,8'd63); write_byte(SHIFT_BASE+2,8'd63);
    run_and_check(127,127,127);

    // ReLU with a non-zero output zero-point must clamp a negative quantized
    // value to output_zp; the other channels exercise positive clamp and zero.
    program_descriptor(8'h03,8'd127,8'd10,8'd127);
    program_common_weights(8'sd1,8'sd0,8'sd0);
    write_signed_byte(WEIGHT_BASE+3,8'sd0); write_signed_byte(WEIGHT_BASE+4,8'sd0); write_signed_byte(WEIGHT_BASE+5,8'sd1);
    write_signed_byte(WEIGHT_BASE+6,8'sd0); write_signed_byte(WEIGHT_BASE+7,8'sd1); write_signed_byte(WEIGHT_BASE+8,8'sd0);
    run_and_check(10,127,10);

    invalid_descriptor_tail();
    max_layer_chain();
    irq_restart_race();
    conv_stride1_case();
    conv_stride2_case();
    cycle_wrap_case();

    if (errors) $fatal(1,"quantization edge regression errors=%0d",errors);
    $display("[CNN-EDGES] PASS backend=%0d shift=0/63, signed extremes, ReLU/qmax, odd FC channels",MEM_BACKEND);
    $finish;
  end
endmodule
