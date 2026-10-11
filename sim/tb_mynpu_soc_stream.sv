`timescale 1ns/1ps

// CPU-in-loop random-vector regression.  The CPU image copies model
// parameters/descriptors through its own AXI data port, waits for a host
// command in the mailbox, starts the NPU and services its completion IRQ.
// The host side injects each already-quantized image through Debug SBA, so
// both masters contend through the real 3x4 SoC crossbar.
module tb_mynpu_soc_stream #(
  parameter integer VECTORS = 64,
  parameter integer NPU_SRAM_BYTES = 8192,
  parameter integer LANES = 8,
  parameter INPUT_HEX = "build/mnist-regression/mnist_input_codes_8k.hex",
  parameter GOLDEN_HEX = "build/mnist-regression/mnist_integer_outputs_8k.hex"
);
  localparam CPU_IMAGE = "generated/8k/cpu_stream.hex";
  localparam integer INPUT_BYTES = 784;
  localparam integer OUTPUT_BYTES = 10;
  localparam integer NPU_INPUT_ADDR = 32'h70004000 + 5120;
  localparam integer MAIL_ADDR = 32'h80001fc0;
  localparam integer CMD_BASE = 32'h53540000;
  localparam integer DONE_BASE = 32'h444f0000;

  logic clk=0, rst_n=0, boot_ready=0;
  logic tck=0, tms=1, tdi=0, tdo, npu_irq, debug_halted;
  logic [7:0] input_codes [0:VECTORS*INPUT_BYTES-1];
  logic [7:0] golden_codes [0:VECTORS*OUTPUT_BYTES-1];
  integer run, word, lane, i, errors;
  logic [31:0] value, expected;
  logic [40:0] scan_response;
  bit discard;

  initial begin
    $readmemh(INPUT_HEX, input_codes);
    $readmemh(GOLDEN_HEX, golden_codes);
  end

  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(NPU_SRAM_BYTES), .NPU_LANES(LANES),
    .CPU_INIT_FILE(CPU_IMAGE), .NPU_INIT_FILE("")
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_ready_i(boot_ready),
    .tck_i(tck), .tms_i(tms), .td_i(tdi), .td_o(tdo),
    .npu_irq_o(npu_irq), .cpu_debug_halted_o(debug_halted)
  );
  always #5 clk=~clk;

  task automatic tick(input bit ms, input bit di, output bit sample);
    tck=0; tms=ms; tdi=di; #20; sample=tdo; tck=1; #20;
  endtask
  task automatic idle_ticks(input integer n);
    bit discard_local;
    repeat(n) tick(0,0,discard_local);
  endtask
  task automatic select_ir(input logic [4:0] ir);
    bit discard_local;
    tick(1,0,discard_local); tick(1,0,discard_local); tick(0,0,discard_local); tick(0,0,discard_local);
    for (integer j=0;j<5;j++) tick(j==4,ir[j],discard_local);
    tick(1,0,discard_local); tick(0,0,discard_local);
  endtask
  task automatic scan_dr(input integer n, input logic [40:0] tx, output logic [40:0] rx);
    bit sample;
    tick(1,0,sample); tick(0,0,sample); tick(0,0,sample); rx=0;
    for (integer j=0;j<n;j++) begin tick(j==n-1,tx[j],sample); rx[j]=sample; end
    tick(1,0,sample); tick(0,0,sample);
  endtask
  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,data,2'b10},response); idle_ticks(64); scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI write failed addr=%h status=%h",addr,response[1:0]);
  endtask
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,32'd0,2'b01},response); idle_ticks(64); scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI read failed addr=%h status=%h",addr,response[1:0]);
    data=response[33:2];
  endtask
  task automatic wait_sba;
    logic [31:0] status;
    for (integer j=0;j<40;j++) begin
      dmi_read(7'h38,status);
      if (status[14:12] || status[22]) $fatal(1,"SBA error %h",status);
      if (!status[21]) return;
    end
    $fatal(1,"SBA timeout");
  endtask
  task automatic sba_write(input logic [31:0] addr, input logic [31:0] data);
    dmi_write(7'h38,32'h00040000); dmi_write(7'h39,addr); dmi_write(7'h3c,data); wait_sba();
  endtask
  task automatic sba_read(input logic [31:0] addr, output logic [31:0] data);
    dmi_write(7'h38,32'h00140000); dmi_write(7'h39,addr); wait_sba(); dmi_read(7'h3c,data);
  endtask

  task automatic load_input_sba(input integer vector_index);
    integer b;
    logic [31:0] word_data;
    begin
      for (word=0; word<INPUT_BYTES/4; word=word+1) begin
        word_data='0;
        for (b=0;b<4;b=b+1)
          word_data[b*8 +: 8] = input_codes[vector_index*INPUT_BYTES + word*4 + b];
        sba_write(NPU_INPUT_ADDR + word*4,word_data);
      end
    end
  endtask

  initial begin
    repeat(10) @(posedge clk);
    @(negedge clk) rst_n=1;
    repeat(10) @(posedge clk);
    repeat(6) tick(1,0,discard); tick(0,0,discard); select_ir(5'h01);
    scan_dr(32,0,scan_response);
    if (scan_response[31:0] !== 32'h00000001) $fatal(1,"JTAG IDCODE mismatch %h",scan_response);
    select_ir(5'h11);
    dmi_write(7'h10,32'd1); // dmactive
    @(negedge clk) boot_ready=1;

    // The stream firmware does CPU-side model loading before advertising READY.
    value=0;
    for (i=0;i<200;i=i+1) begin
      sba_read(MAIL_ADDR,value);
      if (value===32'h5354524d) break;
    end
    if (value!==32'h5354524d) $fatal(1,"stream CPU did not reach READY mailbox=%h",value);
    $display("[SOC-STREAM] CPU model load and READY handshake passed");

    errors=0;
    for (run=0;run<VECTORS;run=run+1) begin
      load_input_sba(run);
      sba_write(MAIL_ADDR,CMD_BASE+run);
      value=0;
      for (i=0;i<300;i=i+1) begin
        sba_read(MAIL_ADDR,value);
        if (value===DONE_BASE+run || value===32'hdeadbeef) break;
      end
      if (value===32'hdeadbeef) $fatal(1,"stream CPU firmware failed vector=%0d code=%h",run,value);
      if (value!==DONE_BASE+run) $fatal(1,"stream CPU completion timeout vector=%0d mailbox=%h",run,value);
      for (lane=0;lane<OUTPUT_BYTES;lane=lane+1) begin
        sba_read(MAIL_ADDR+16+lane*4,value);
        expected=golden_codes[run*OUTPUT_BYTES+lane];
        if (value!==expected) begin
          $display("[SOC-STREAM] vector=%0d output[%0d] hw=%0d expected=%0d",run,lane,value,expected);
          errors=errors+1;
        end
      end
      if ((run % 8)==0) $display("[SOC-STREAM] vector=%0d/%0d CPU IRQ/NPU result passed",run,VECTORS);
    end
    if (errors) $fatal(1,"CPU-in-loop random regression errors=%0d",errors);
    $display("[SOC-STREAM] PASS CPU-in-loop vectors=%0d, Debug SBA input injection, CPU AXI model load, NPU IRQ and result readback",VECTORS);
    $finish;
  end
  initial begin #1000000000; $fatal(1,"CPU-in-loop stream timeout"); end
endmodule
