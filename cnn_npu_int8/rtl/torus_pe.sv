`timescale 1ns/1ps
// Four architectural DATA registers. One broadcast instruction executes at an
// accepted clock edge; no PE PC, instruction store or neural-network sequencer.
module torus_pe(
  input logic clk_i,rst_ni,execute_i,
  input logic[5:0] operation_i,
  input logic[1:0] destination_i,
  input logic[31:0] operand_a_i,operand_b_i,
  input logic load0_i,load1_i,
  input logic[1:0] load0_reg_i,load1_reg_i,
  input logic[31:0] load0_data_i,load1_data_i,
  input logic[3:0] load0_be_i,load1_be_i,
  output logic[31:0] registers_o[0:3]
);
  wire[31:0] old_destination=registers_o[destination_i];
  function automatic logic[31:0] merge(input logic[31:0]old_value,new_value,input logic[3:0]enables);
    for(integer k=0;k<4;k++)merge[k*8+:8]=enables[k]?new_value[k*8+:8]:old_value[k*8+:8];
  endfunction
  logic signed[31:0] mul_a,mul_b;
  logic signed[63:0] product;
  logic[31:0] next_value,add_a,add_b,add_result,reversed,shift_result;
  logic carry_in,unsigned_less,signed_less;
  logic[31:0] shift_stage[0:5],count_input;
  logic shift_left,shift_rotate,shift_sign;
  logic[1:0] count2[0:15];
  logic[2:0] count4[0:7];
  logic[3:0] count8[0:3];
  logic[4:0] count16[0:1];
  logic[5:0] leading,trailing,population;
  function automatic logic[5:0] count_leading(input logic[31:0]value);
    logic[31:0]v;
    logic[4:0]n;
    begin
      v=value;n=0;
      if(v[31:16]==0)begin n=n+16;v=v<<16;end
      if(v[31:24]==0)begin n=n+8;v=v<<8;end
      if(v[31:28]==0)begin n=n+4;v=v<<4;end
      if(v[31:30]==0)begin n=n+2;v=v<<2;end
      if(v[31]==0)n=n+1;
      count_leading=(value==0)?6'd32:{1'b0,n};
    end
  endfunction
  always_comb begin
    mul_a=$signed(operand_a_i);mul_b=$signed(operand_b_i);
    case(operation_i)
      5,6:begin mul_a=$signed(operand_a_i[8:0]);mul_b=$signed(operand_b_i[7:0]);end
      21,22:begin mul_a=$signed(operand_a_i[7:0]);mul_b=$signed(operand_b_i[7:0]);end
      23,24:begin mul_a=$signed(operand_a_i[15:0]);mul_b=$signed(operand_b_i[15:0]);end
      49:begin mul_a=$signed({1'b0,operand_a_i[7:0]});mul_b=$signed({1'b0,operand_b_i[7:0]});end
      50:begin mul_a=$signed({1'b0,operand_a_i[15:0]});mul_b=$signed({1'b0,operand_b_i[15:0]});end
      default:;
    endcase
    product=mul_a*mul_b;
    for(integer i=0;i<32;i++)reversed[i]=operand_a_i[31-i];
    shift_left=operation_i==10||operation_i==38;
    shift_rotate=operation_i==38||operation_i==39;
    shift_sign=(operation_i==12||operation_i==43)&&operand_a_i[31];
    shift_stage[0]=shift_left?reversed:operand_a_i;
    // One barrel network for logical/arithmetic shifts AND rotations. Each
    // stage selects only its upper fill bits; the shift distances are wires.
    for(integer j=0;j<5;j++)begin
      shift_stage[j+1]=shift_stage[j];
      if(operand_b_i[j])shift_stage[j+1]=(shift_stage[j]>>(1<<j))|
        ((shift_rotate?shift_stage[j]:{32{shift_sign}})<<(32-(1<<j)));
    end
    for(integer i=0;i<32;i++)shift_result[i]=shift_left?shift_stage[5][31-i]:shift_stage[5][i];
    add_a=old_destination;add_b=product[31:0];carry_in=0;
    case(operation_i)
      3:begin add_a=operand_a_i;add_b=operand_b_i;end
      4:begin add_a=operand_a_i;add_b=~operand_b_i;carry_in=1;end
      17:begin add_a=old_destination;add_b=operand_a_i;end
      18,19:begin add_a=~operand_a_i;add_b=0;carry_in=1;end
      // floor(a/2^s) + the highest discarded bit is exact round-to-+infinity
      // at ties. This replaces a separate 33-bit rounding adder/barrel path.
      43:begin add_a=shift_result;add_b={31'd0,(|operand_b_i[4:0])&&operand_a_i[operand_b_i[4:0]-5'd1]};end
      51:begin add_a=product[63:32];add_b={31'd0,product[31]};end
      default:;
    endcase
    add_result=add_a+add_b+carry_in;
    unsigned_less=operand_a_i<operand_b_i;
    signed_less=(operand_a_i[31]!=operand_b_i[31])?operand_a_i[31]:unsigned_less;
    count_input=operation_i==41?reversed:operand_a_i;
    leading=count_leading(count_input);trailing=leading;
    for(integer i=0;i<16;i++)count2[i]={1'b0,operand_a_i[i*2]}+{1'b0,operand_a_i[i*2+1]};
    for(integer i=0;i<8;i++)count4[i]={1'b0,count2[i*2]}+{1'b0,count2[i*2+1]};
    for(integer i=0;i<4;i++)count8[i]={1'b0,count4[i*2]}+{1'b0,count4[i*2+1]};
    for(integer i=0;i<2;i++)count16[i]={1'b0,count8[i*2]}+{1'b0,count8[i*2+1]};
    population={1'b0,count16[0]}+{1'b0,count16[1]};
    next_value=old_destination;
    case(operation_i)
      0:next_value=old_destination; // HOLD; reserved operations also hold
      1:next_value=operand_a_i;
      2:next_value=operand_b_i;
      3,4,6,17,18,19,22,24,26,43,51:next_value=add_result;
      5,21,23,25,49,50:next_value=product[31:0];
      7:next_value=operand_a_i&operand_b_i;
      8:next_value=operand_a_i|operand_b_i;
      9:next_value=operand_a_i^operand_b_i;
      10,11,12:next_value=shift_result;
      13:next_value=signed_less?operand_a_i:operand_b_i;
      14:next_value=signed_less?operand_b_i:operand_a_i;
      15:next_value={31'd0,signed_less};
      16:next_value={31'd0,unsigned_less};
      20:next_value=~operand_a_i;
      27:next_value=product[63:32];
      28:next_value=unsigned_less?operand_a_i:operand_b_i;
      29:next_value=unsigned_less?operand_b_i:operand_a_i;
      30:next_value={31'd0,operand_a_i==operand_b_i};
      31:next_value={31'd0,operand_a_i!=operand_b_i};
      32:next_value={31'd0,signed_less||operand_a_i==operand_b_i};
      33:next_value={31'd0,unsigned_less||operand_a_i==operand_b_i};
      34:next_value={{24{operand_a_i[7]}},operand_a_i[7:0]};
      35:next_value={{16{operand_a_i[15]}},operand_a_i[15:0]};
      36:next_value={24'd0,operand_a_i[7:0]};
      37:next_value={16'd0,operand_a_i[15:0]};
      38,39:next_value=shift_result;
      40:next_value={26'd0,leading};
      41:next_value={26'd0,trailing};
      42:next_value={26'd0,population};
      44:next_value=($signed(operand_a_i)<-128)?32'hffffff80:(($signed(operand_a_i)>127)?32'd127:operand_a_i);
      45:next_value=($signed(operand_a_i)<-32768)?32'hffff8000:(($signed(operand_a_i)>32767)?32'd32767:operand_a_i);
      46:next_value=operand_a_i[31]?32'd0:((operand_a_i>255)?32'd255:operand_a_i);
      47:next_value=operand_a_i[31]?32'd0:((operand_a_i>65535)?32'd65535:operand_a_i);
      48:next_value=old_destination[0]?operand_a_i:operand_b_i;
      52:next_value=operand_a_i[31]?0:(unsigned_less?operand_a_i:operand_b_i);
      default:;
    endcase
    if(operation_i==18&&!operand_a_i[31])next_value=operand_a_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin for(integer k=0;k<4;k++)registers_o[k]<=0;end
    else begin
      if(execute_i)registers_o[destination_i]<=next_value;
      if(load0_i)registers_o[load0_reg_i]<=merge(registers_o[load0_reg_i],load0_data_i,load0_be_i);
      if(load1_i)registers_o[load1_reg_i]<=merge(registers_o[load1_reg_i],load1_data_i,load1_be_i);
    end
  end
endmodule
