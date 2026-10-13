`timescale 1ns/1ps
module tb_cnn_npu_vector_stress #(
  parameter integer MEM_BACKEND=1,
  parameter integer LANES=4,
  parameter integer CASES=200
);
  logic clk=0,rst_ni=0,ena=0,wea=0,irq;
  logic [3:0] be=4'hf;
  logic [13:0] addr=0;
  logic [31:0] wdata=0,rdata,status,value;
  logic [31:0] inputs[0:CASES*2048-1],gold[0:CASES*2048-1];
  integer vector_macs,full_lane_macs,total_irqs;
  always #5 clk=~clk;
  cnn_npu_sp_lanes #(.LANES(LANES),.MEM_BACKEND(MEM_BACKEND)) dut(
    .clka(clk),.rst_ni(rst_ni),.ena(ena),.wea(wea),.be_i(be),
    .addra(addr),.dina(wdata),.douta(rdata),.irq_o(irq));
  always @(posedge irq) total_irqs++;
  always @(posedge clk) if (rst_ni && dut.state_q==dut.S_MAC) begin
    vector_macs++;
    if(dut.lane_count_q==LANES) full_lane_macs++;
    if (dut.lane_count_q<1 || dut.lane_count_q>LANES) $fatal(1,"Invalid lane mask");
    if($isunknown(dut.activation_q)) $fatal(1,"X activation on vector MAC");
  end
  task automatic write_word(input integer a,input logic[31:0] d);
    @(negedge clk);ena=1;wea=1;addr=a;wdata=d;
    @(negedge clk);ena=0;wea=0;addr=0;wdata=0;
  endtask
  task automatic read_word(input integer a,output logic[31:0] d);
    @(negedge clk);ena=1;wea=0;addr=a;
    @(posedge clk);@(negedge clk);@(posedge clk);#1 d=rdata;
    @(negedge clk);ena=0;addr=0;
  endtask
  initial begin
    $readmemh("build/npu-vector-stress/input.hex",inputs);
    $readmemh("build/npu-vector-stress/expected.hex",gold);
    vector_macs=0;full_lane_macs=0;total_irqs=0;
    repeat(4) @(negedge clk);rst_ni=1;
    for(integer c=0;c<CASES;c++) begin
      for(integer w=0;w<2048;w++) write_word('h1000+w,inputs[c*2048+w]);
      write_word(4,0);write_word(5,1);write_word(0,3);
      status=0;
      for(integer p=0;p<100000;p++) begin
        read_word(1,status);if(status[1]||status[2]) break;
      end
      if(!status[1]||status[2]||!irq) $fatal(1,"Random case=%0d status=%h",c,status);
      for(integer w=0;w<2048;w++) begin
        read_word('h1000+w,value);
        if(value!==gold[c*2048+w])
          $fatal(1,"Random case=%0d word=%0d got=%h golden=%h",c,w,value,gold[c*2048+w]);
      end
      write_word(0,4);
      if(irq) $fatal(1,"IRQ clear failed case=%0d",c);
      if(c%25==24) $display("[CNN-VECTOR-STRESS] cases=%0d/%0d",c+1,CASES);
      // Warm resets retain macro contents but must invalidate every cache.
      if(c%11==10) begin
        @(negedge clk);rst_ni=0;repeat(3) @(negedge clk);rst_ni=1;
      end
    end
    if(total_irqs!=CASES||full_lane_macs==0) $fatal(1,"IRQ/vector coverage missing");
    $display("[CNN-VECTOR-STRESS] PASS backend=%0d lanes=%0d cases=%0d full SRAM compare, vector_MAC_edges=%0d full_lane_edges=%0d",MEM_BACKEND,LANES,CASES,vector_macs,full_lane_macs);
    $finish;
  end
  initial begin #1000000000; $fatal(1,"Vector stress timeout");end
endmodule
