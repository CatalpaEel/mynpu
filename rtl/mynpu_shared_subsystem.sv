// CPU physical-bank aliases and an NPU word-striped view refer to the SAME
// two physical macros. No mirror arrays, third SRAM, or hidden memory port.
module mynpu_shared_subsystem #(
  parameter integer LANES=4,MEM_BACKEND=1,ACT_CACHE_WORDS=1,
  parameter BANK0_INIT_FILE="",BANK1_INIT_FILE=""
)(
  input logic clk_i,rst_ni,req_i,we_i,
  input logic[31:0] addr_i,wdata_i,
  input logic[3:0] be_i,
  output logic gnt_o,rvalid_o,error_o,
  output logic[31:0] rdata_o,
  output logic irq_o,
  output logic host_write_o,
  output logic[31:0] host_addr_o,host_wdata_o,
  output logic[3:0] host_be_o
);
  logic reg_access,memory_access,reg_response_q,bad_response_q;
  logic[31:0] register_data,reg_data_q,register_wdata;
  logic[2:0] req,we,gnt,rv;
  logic[13:0] addr[0:2],eng_addr[0:1];
  logic[3:0] be[0:2],eng_be[0:1];
  logic[31:0] wd[0:2],rd[0:2],eng_wd[0:1],eng_rd[0:1];
  logic[1:0] eng_req,eng_we;
  logic busy;
  assign reg_access=(addr_i>=32'h70000000)&&(addr_i<32'h70000020);
  assign memory_access=((addr_i>=32'h80000000)&&(addr_i<32'h80004000))||
                       ((addr_i>=32'h70004000)&&(addr_i<32'h70008000));
  // CPU 0x80000000..1fff -> bank0; 0x80002000..3fff -> bank1.
  // NPU 0x70004000..7fff -> byte-addressed 16KB word-striped logical space.
  assign addr[0]=(addr_i[31:28]==8)?{addr_i[12:2],addr_i[13],addr_i[1:0]}:addr_i[13:0];
  assign req[0]=req_i&&memory_access;assign we[0]=we_i;assign be[0]=be_i;assign wd[0]=wdata_i;
  assign req[2:1]=eng_req;assign we[2:1]=eng_we;
  for(genvar p=0;p<2;p++)begin:g_ports
    assign addr[p+1]=eng_addr[p];assign be[p+1]=eng_be[p];assign wd[p+1]=eng_wd[p];assign eng_rd[p]=rd[p+1];
  end
  assign gnt_o=req_i&&(memory_access?gnt[0]:1'b1);
  assign rvalid_o=rv[0]||reg_response_q||bad_response_q;
  assign error_o=bad_response_q;
  assign rdata_o=rv[0]?rd[0]:reg_data_q;
  assign host_write_o=req_i&&gnt_o&&we_i&&memory_access;
  assign host_addr_o=addr_i;assign host_wdata_o=wdata_i;assign host_be_o=be_i;
  for(genvar b=0;b<4;b++)begin:g_reg_bytes
    assign register_wdata[b*8+:8]=be_i[b]?wdata_i[b*8+:8]:register_data[b*8+:8];
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin reg_response_q<=0;bad_response_q<=0;reg_data_q<=0;end
    else begin
      reg_response_q<=req_i&&gnt_o&&reg_access;
      bad_response_q<=req_i&&gnt_o&&!reg_access&&!memory_access;
      if(req_i&&gnt_o&&!memory_access)reg_data_q<=reg_access?register_data:0;
    end
  end
  cnn_npu_banked #(.LANES(LANES),.ACT_CACHE_WORDS(ACT_CACHE_WORDS)) i_core(.clk_i(clk_i),.rst_ni(rst_ni),
    .host_write_i(host_write_o),.host_addr_i(addr[0]),
    .reg_req_i(req_i&&gnt_o&&reg_access),.reg_we_i(we_i),.reg_addr_i(addr_i[4:0]),
    .reg_wdata_i(register_wdata),.reg_rdata_o(register_data),.irq_o(irq_o),.busy_o(busy),
    .req_o(eng_req),.we_o(eng_we),.addr_o(eng_addr),.be_o(eng_be),.wdata_o(eng_wd),
    .gnt_i(gnt[2:1]),.rvalid_i(rv[2:1]),.rdata_i(eng_rd));
  mynpu_banked_sram #(.MEM_BACKEND(MEM_BACKEND),.BANK0_INIT_FILE(BANK0_INIT_FILE),
    .BANK1_INIT_FILE(BANK1_INIT_FILE)) i_memory(.clk_i(clk_i),.rst_ni(rst_ni),
    .req_i(req),.we_i(we),.addr_i(addr),.be_i(be),.wdata_i(wd),.gnt_o(gnt),.rvalid_o(rv),.rdata_o(rd));
endmodule
