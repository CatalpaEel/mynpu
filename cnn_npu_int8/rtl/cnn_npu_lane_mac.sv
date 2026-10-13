`timescale 1ns/1ps
// One explicitly instantiated signed 9x8 -> 17-bit MAC lane. Accumulation
// wraps modulo 2^32, matching the independent integer golden.
(* keep_hierarchy = "yes" *)
module cnn_npu_lane_mac (
  input logic clk_i,rst_ni,load_i,mac_i,
  input logic signed [8:0] activation_i,
  input logic signed [7:0] weight_i,
  input logic signed [31:0] bias_i,
  output logic signed [31:0] acc_o
);
  wire signed [16:0] product=activation_i*weight_i;
  always @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) acc_o<=0;
    else if(load_i) acc_o<=bias_i;
    else if(mac_i) acc_o<=acc_o+$signed(product);
  end
endmodule
