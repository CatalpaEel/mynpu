`timescale 1ns/1ps
// Three requesters, two independent synchronous SINGLE-PORT 2048x32 macros.
// Logical byte addresses are word striped: bank=addr[2], row=addr[13:3].
// Every accepted request (including writes) has a one-cycle response. Per-bank
// round robin prevents CPU/debug starvation under continuous engine traffic.
module mynpu_banked_sram #(
  parameter integer MEM_BACKEND=1,
  parameter BANK0_INIT_FILE="", parameter BANK1_INIT_FILE=""
) (
  input logic clk_i, rst_ni,
  input logic [2:0] req_i, we_i,
  input logic [13:0] addr_i [0:2],
  input logic [3:0] be_i [0:2],
  input logic [31:0] wdata_i [0:2],
  output logic [2:0] gnt_o, rvalid_o,
  output logic [31:0] rdata_o [0:2]
);
  logic [1:0] rr_q[0:1], owner_q[0:1], chosen[0:1];
  logic [1:0] bank_req, bank_we, response_q;
  logic [10:0] bank_addr[0:1];
  logic [3:0] bank_be[0:1];
  logic [31:0] bank_wdata[0:1], bank_rdata[0:1];
  integer b,k,p;
  always_comb begin
    gnt_o='0; rvalid_o='0;
    for(integer c=0;c<3;c++) rdata_o[c]='0;
    bank_req='0; bank_we='0;
    for(b=0;b<2;b++) begin
      chosen[b]=0; bank_addr[b]='0; bank_be[b]='0; bank_wdata[b]='0;
      for(k=0;k<3;k++) begin
        p=rr_q[b]+k; if(p>=3) p=p-3;
        if(rst_ni && !bank_req[b] && req_i[p] && addr_i[p][2]==b) begin
          chosen[b]=p; bank_req[b]=1; bank_we[b]=we_i[p];
          bank_addr[b]=addr_i[p][13:3]; bank_be[b]=be_i[p];
          bank_wdata[b]=wdata_i[p]; gnt_o[p]=1;
        end
      end
      if(response_q[b]) begin
        rvalid_o[owner_q[b]]=1; rdata_o[owner_q[b]]=bank_rdata[b];
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      response_q<=0;
      for(integer n=0;n<2;n++) begin rr_q[n]<=0;owner_q[n]<=0;end
    end else begin
      response_q<=bank_req;
      for(integer n=0;n<2;n++) if(bank_req[n]) begin
        owner_q[n]<=chosen[n]; rr_q[n]<=(chosen[n]==2)?0:chosen[n]+1'b1;
      end
    end
  end
  generate for(genvar n=0;n<2;n++) begin:g_bank
    if(MEM_BACKEND==2) begin:g_asic
      mynpu_sram_2048x32_asic i_mem(.clk_i(clk_i),.req_i(bank_req[n]),
        .we_i(bank_we[n]),.be_i(bank_be[n]),.addr_i(bank_addr[n]),
        .wdata_i(bank_wdata[n]),.rdata_o(bank_rdata[n]));
    end else begin:g_fpga
      mynpu_sram_2048x32_fpga #(.INIT_FILE(n==0?BANK0_INIT_FILE:BANK1_INIT_FILE))
      i_mem(.clk_i(clk_i),.req_i(bank_req[n]),.we_i(bank_we[n]),
        .be_i(bank_be[n]),.addr_i(bank_addr[n]),.wdata_i(bank_wdata[n]),.rdata_o(bank_rdata[n]));
    end
  end endgenerate
  initial if(!(MEM_BACKEND==1||MEM_BACKEND==2)) $fatal(1,"banked SRAM backend must be FPGA=1 or ASIC=2");
endmodule
