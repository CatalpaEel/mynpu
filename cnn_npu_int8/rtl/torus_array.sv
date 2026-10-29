`timescale 1ns/1ps
// Shared decoder, sixteen four-register PEs, and uniform N/S/W/E wrap links.
module torus_array(
  input logic clk_i,rst_ni,command_i,
  input logic[31:0] command_word_i,
  input logic[15:0] load_mask_i[0:1][0:3],
  input logic[31:0] load_data_i[0:1][0:3],
  input logic[1:0] load_reg_i[0:1],
  input logic debug_write_i,
  input logic[3:0] debug_pe_i,
  input logic[1:0] debug_reg_i,
  input logic[31:0] debug_data_i,
  input logic[3:0] debug_be_i,
  output wire[31:0] registers_o[0:15][0:3]
);
  wire[5:0]op=command_word_i[31:26];
  wire[1:0]dst=command_word_i[25:24];
  wire[4:0]sa=command_word_i[23:19],sb=command_word_i[18:14];
  wire[3:0]mask=command_word_i[13:10];
  wire[31:0]immediate={{23{command_word_i[8]}},command_word_i[8:0]};
  for(genvar p=0;p<16;p++)begin:g_pe
    localparam integer N=((p/4+3)%4)*4+p%4,S=((p/4+1)%4)*4+p%4;
    localparam integer W=(p/4)*4+(p%4+3)%4,E=(p/4)*4+(p%4+1)%4;
    logic[31:0]a,b,ld0,ld1;
    logic en0,en1;
    logic[1:0]lr0;
    logic[3:0]be0;
    always_comb begin
      // Each operand chooses a direction and a two-bit register number.
      // ALU destinations always belong to THIS PE, never to the source PE.
      case(sa[4:2])
        0:a=registers_o[p][sa[1:0]];
        1:a=registers_o[N][sa[1:0]];2:a=registers_o[S][sa[1:0]];
        3:a=registers_o[W][sa[1:0]];4:a=registers_o[E][sa[1:0]];default:a=0;
      endcase
      case(sb[4:2])
        0:b=registers_o[p][sb[1:0]];
        1:b=registers_o[N][sb[1:0]];2:b=registers_o[S][sb[1:0]];
        3:b=registers_o[W][sb[1:0]];4:b=registers_o[E][sb[1:0]];default:b=0;
      endcase
      if(command_word_i[9])b=immediate;
      en0=0;en1=0;ld0=0;ld1=0;lr0=load_reg_i[0];be0=15;
      for(integer k=0;k<4;k++)begin
        en0|=load_mask_i[0][k][p];en1|=load_mask_i[1][k][p];
        ld0|=load_data_i[0][k]&{32{load_mask_i[0][k][p]}};
        ld1|=load_data_i[1][k]&{32{load_mask_i[1][k][p]}};
      end
      if(debug_write_i&&debug_pe_i==p)begin en0=1;ld0=debug_data_i;lr0=debug_reg_i;be0=debug_be_i;end
    end
    torus_pe i_pe(.clk_i(clk_i),.rst_ni(rst_ni),.execute_i(command_i&&op<=52&&mask[p/4]),
      .operation_i(op),.destination_i(dst),.operand_a_i(a),.operand_b_i(b),
      .load0_i(en0),.load1_i(en1),.load0_reg_i(lr0),.load1_reg_i(load_reg_i[1]),
      .load0_data_i(ld0),.load1_data_i(ld1),.load0_be_i(be0),.load1_be_i(4'hf),
      .registers_o(registers_o[p]));
  end
endmodule
