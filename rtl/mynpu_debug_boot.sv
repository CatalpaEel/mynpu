// Optional 64B JTAG boot ROM/control page. CPU waits here while SBA loads SRAM.
// The CPU remains executable so Lab6 OpenOCD/GDB can halt and inspect it.
module mynpu_debug_boot #(
  parameter logic [31:0] BUILD_ID=32'h4a541004,
  parameter integer CACHE_WORDS=0
)(
  input logic clk_i,rst_ni,req_i,we_i,
  input logic [3:0] addr_i,be_i,
  input logic [31:0] wdata_i,
  output logic [31:0] rdata_o
);
  logic run_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin run_q<=0;rdata_o<=0;end
    else begin
      rdata_o<=0;
      if(req_i)begin
        case(addr_i)
          0:rdata_o<=32'h000102b7; // lui t0,0x10
          1:rdata_o<=32'h0302a303; // wait: lw t1,48(t0)
          2:rdata_o<=32'h00137313; // andi t1,t1,1
          3:rdata_o<=32'hfe030ce3; // beq t1,zero,wait
          4:rdata_o<=32'h800002b7; // lui t0,0x80000
          5:rdata_o<=32'h00028067; // jr t0
          12:rdata_o<={31'd0,run_q}; // 0x10030: RUN
          13:rdata_o<=BUILD_ID;      // 0x10034: protocol/layout/lanes
          14:rdata_o<=CACHE_WORDS;   // 0x10038: activation cache words
          default:rdata_o<=0;
        endcase
        if(we_i&&addr_i==12&&be_i[0])run_q<=wdata_i[0];
      end
    end
  end
endmodule
