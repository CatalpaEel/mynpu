`timescale 1ns/1ps

// Standalone check for the real single-port SRAM schedule.  The word-packed
// image is loaded into the FPGA BRAM model; the same test can be compiled with
// the foundry .v model and MEM_BACKEND=2 in an ASIC simulation.
module tb_cnn_npu_sp #(
  parameter integer RUNS = 5,
  parameter bit STRESS_MODE = 1'b1,
  parameter integer MEM_BACKEND = 1,
  parameter integer LANES = 1,
  parameter MEM_HEX = (LANES==1) ? "cnn_npu_int8/generated/8k/npu_word.hex" : "cnn_npu_int8/generated/8k-p4/npu_word.hex"
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
  logic [31:0] cycle_count;
  logic engine_write,engine_busy;
  integer engine_byte_addr,engine_layer;
  logic [31:0] engine_wdata;
  logic [3:0] engine_be;
  logic [7:0] integer_layers[0:1793],pytorch_layers[0:1793];
  integer layer_errors=0,layer_writes=0;
  logic [7:0] input_image [0:INPUT_BYTES-1];
  logic [31:0] init_words [0:2047];
  always #5 clk=~clk;
  initial begin
    $readmemh("cnn_npu_int8/generated/8k/input_codes.hex",input_image);
    $readmemh("generated/8k/integer_layers.hex",integer_layers);
    $readmemh("generated/8k/pytorch_layers.hex",pytorch_layers);
    if (MEM_BACKEND==2) $readmemh(MEM_HEX,init_words);
  end

  generate
    if (LANES == 1) begin : g_scalar
      cnn_npu_sp_top #(
        .LANES(1), .SRAM_BYTES(8192), .MAX_LAYERS(8), .MEM_BACKEND(MEM_BACKEND),
        .MEM_INIT_FILE(MEM_BACKEND==1 ? MEM_HEX : "")
      ) dut (.clka(clk),.rst_ni(rst_ni),.ena(ena),.wea(wea),.be_i(be),
             .addra(addra),.dina(dina),.douta(douta),.irq_o(irq));
    end else begin : g_lanes
      cnn_npu_sp_lanes #(
        .LANES(LANES), .SRAM_BYTES(8192), .MAX_LAYERS(8), .MEM_BACKEND(MEM_BACKEND),
        .MEM_INIT_FILE(MEM_BACKEND==1 ? MEM_HEX : "")
      ) dut (.clka(clk),.rst_ni(rst_ni),.ena(ena),.wea(wea),.be_i(be),
             .addra(addra),.dina(dina),.douta(douta),.irq_o(irq));
    end
  endgenerate
  generate
    if (LANES == 1) begin : g_scalar_cycle
      always_comb cycle_count = g_scalar.dut.cycle_q;
      assign engine_write=g_scalar.dut.eng_req && g_scalar.dut.eng_we;
      assign engine_byte_addr=g_scalar.dut.eng_byte_addr;
      assign engine_layer=g_scalar.dut.layer_q;
      assign engine_busy=g_scalar.dut.busy_q;
      assign engine_wdata=g_scalar.dut.eng_wdata;
      assign engine_be=g_scalar.dut.eng_be;
    end else begin : g_lanes_cycle
      always_comb cycle_count = g_lanes.dut.cycle_q;
      assign engine_write=g_lanes.dut.eng_req && g_lanes.dut.eng_we;
      assign engine_byte_addr=g_lanes.dut.eng_byte_addr;
      assign engine_layer=g_lanes.dut.layer_q;
      assign engine_busy=g_lanes.dut.busy_q;
      assign engine_wdata=g_lanes.dut.eng_wdata;
      assign engine_be=g_lanes.dut.eng_be;
    end
  endgenerate

  // Check each accepted engine write at the physical macro port. This sees
  // all six layers without reading memory behind the host arbitration.
  always @(posedge clk) if(rst_ni && engine_busy && engine_write) begin : check_layer_write
    integer offset,base,idx,q,delta;
    case(engine_layer)
      0: offset=0; 1: offset=392; 2: offset=1176;
      3: offset=1568; 4: offset=1640; 5: offset=1784;
      default: $fatal(1,"Unexpected output layer");
    endcase
    base=(engine_layer==0 || engine_layer==2 || engine_layer==4)?6656:5120;
    idx=offset+engine_byte_addr-base;
    if(idx<0 || idx>=1794 || engine_be!==(4'b0001 << (engine_byte_addr&3)))
      $fatal(1,"Output address/mask invalid layer=%0d addr=%0d",engine_layer,engine_byte_addr);
    q=(engine_wdata >> ((engine_byte_addr&3)*8))&255;
    delta=q-integer'(pytorch_layers[idx]);
    if(q!==integer_layers[idx] || delta < -1 || delta > 1) begin
      $display("[CNN-SP] layer=%0d byte=%0d hw=%0d integer=%0d PyTorch=%0d",engine_layer,idx-offset,q,integer_layers[idx],pytorch_layers[idx]);
      layer_errors++;
    end
    layer_writes++;
  end

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
    if (MEM_BACKEND==2)
      for (i=0;i<2048;i=i+1) bus_write(LOCAL_BASE+i,init_words[i]);
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
    if(layer_errors || layer_writes!=RUNS*1794)
      $fatal(1,"layer golden errors=%0d writes=%0d expected=%0d",layer_errors,layer_writes,RUNS*1794);
    $display("[CNN-SP] PASS backend=%0d lanes=%0d %0d repeated runs, %0d exact layer bytes, PyTorch delta<=1, polls=%0d cycles=%0d",MEM_BACKEND,LANES,RUNS,layer_writes,polls,cycle_count);
    $finish;
  end
endmodule
