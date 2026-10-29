`timescale 1ns/1ps
// Ordered native CPU instruction/data/SBA requests. One response slot, with
// simultaneous retirement/acceptance. SRAM arbitration remains in the shared
// subsystem; a denied request never acknowledges or supplies fake read data.
module mynpu_host_arbiter(
  input logic clk_i,rst_ni,
  input logic[2:0] req_i,we_i,
  input logic[31:0] addr_i[0:2],wdata_i[0:2],
  input logic[3:0] be_i[0:2],
  output logic[2:0] gnt_o,rvalid_o,
  output logic[31:0] rdata_o[0:2],
  output logic shared_req_o,shared_we_o,
  output logic[31:0] shared_addr_o,shared_wdata_o,
  output logic[3:0] shared_be_o,
  input logic shared_gnt_i,shared_rvalid_i,
  input logic[31:0] shared_rdata_i,
  output logic boot_req_o,boot_we_o,dm_req_o,dm_we_o,
  output logic[31:0] boot_addr_o,boot_wdata_o,dm_addr_o,dm_wdata_o,
  output logic[3:0] boot_be_o,dm_be_o,
  input logic[31:0] boot_rdata_i,dm_rdata_i
);
  localparam SHARED=0,BOOT=1,DM=2,BAD=3;
  logic[1:0] rr_q,owner_q,target_q,selected,target;
  logic pending_q,valid,retire,allow,accepted;
  logic[31:0] response;
  integer probe;
  always_comb begin
    retire=pending_q&&((target_q!=SHARED)||shared_rvalid_i);
    case(target_q)SHARED:response=shared_rdata_i;BOOT:response=boot_rdata_i;DM:response=dm_rdata_i;default:response=32'hdeadbeef;endcase
    allow=rst_ni&&(!pending_q||retire);valid=0;selected=0;probe=0;
    for(integer k=0;k<3;k++)begin
      probe=rr_q+k;if(probe>=3)probe-=3;
      if(!valid&&req_i[probe])begin valid=1;selected=probe;end
    end
    target=BAD;
    if((addr_i[selected]>=32'h80000000&&addr_i[selected]<32'h80004000)||
       (addr_i[selected]>=32'h70000000&&addr_i[selected]<32'h70010000))target=SHARED;
    else if(addr_i[selected]>=32'h10000&&addr_i[selected]<32'h10040)target=BOOT;
    else if(addr_i[selected]<32'h1000)target=DM;
    shared_req_o=allow&&valid&&target==SHARED;
    boot_req_o=allow&&valid&&target==BOOT;dm_req_o=allow&&valid&&target==DM;
    shared_we_o=we_i[selected];boot_we_o=we_i[selected];dm_we_o=we_i[selected];
    shared_addr_o=addr_i[selected];boot_addr_o=addr_i[selected];dm_addr_o=addr_i[selected];
    shared_wdata_o=wdata_i[selected];boot_wdata_o=wdata_i[selected];dm_wdata_o=wdata_i[selected];
    shared_be_o=be_i[selected];boot_be_o=be_i[selected];dm_be_o=be_i[selected];
    accepted=allow&&valid&&((target!=SHARED)||shared_gnt_i);
    gnt_o=0;rvalid_o=0;
    for(integer m=0;m<3;m++)rdata_o[m]=0;
    if(accepted)gnt_o[selected]=1;
    if(retire)begin rvalid_o[owner_q]=1;rdata_o[owner_q]=response;end
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin rr_q<=0;owner_q<=0;target_q<=BAD;pending_q<=0;end
    else begin
      if(retire)pending_q<=0;
      // A blocked MMIO action must not block another master's debug/ROM access.
      if(allow&&valid)rr_q<=selected==2?0:selected+1;
      if(accepted)begin pending_q<=1;owner_q<=selected;target_q<=target;end
    end
  end
endmodule
