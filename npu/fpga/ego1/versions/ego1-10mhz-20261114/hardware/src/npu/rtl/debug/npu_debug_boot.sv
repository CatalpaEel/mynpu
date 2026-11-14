// Immutable bootstrap at 0x00010000. IRQ31 wakes WFI when RUN becomes 1.
module npu_debug_boot (
  input logic [3:0] word_i,
  output logic [31:0] data_o
);
  always_comb
    case (word_i)
      4'd0: data_o = 32'h80000337;
      4'd1: data_o = 32'h30431073;
      4'd2: data_o = 32'h400002b7;
      4'd3: data_o = 32'h0082a303;
      4'd4: data_o = 32'h00137313;
      4'd5: data_o = 32'h00031663;
      4'd6: data_o = 32'h10500073;
      4'd7: data_o = 32'hff1ff06f;
      4'd8: data_o = 32'h00c2a303;
      4'd9: data_o = 32'h30401073;
      4'd10: data_o = 32'h00030067;
      default: data_o = 32'h0000006f;
    endcase
endmodule
