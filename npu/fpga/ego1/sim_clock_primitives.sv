`timescale 1ns/1ps
// Functional stand-ins for VCS only. Never include in Vivado sources.
// They validate the wrapper's /2 clock/reset sequence, not MMCM analog behavior.
module BUFG(input wire I, output wire O);
  assign O = I;
endmodule
module MMCME2_BASE #(
  parameter BANDWIDTH="OPTIMIZED", CLKFBOUT_MULT_F=10.0,
  DIVCLK_DIVIDE=1, CLKIN1_PERIOD=10.0, CLKOUT0_DIVIDE_F=20.0,
  REF_JITTER1=0.010
)(input wire CLKIN1, CLKFBIN, RST, PWRDWN,
  output wire CLKFBOUT, output logic CLKOUT0=0, LOCKED=0);
  int lock_count=0;
  assign CLKFBOUT=CLKIN1;
  initial if (CLKFBOUT_MULT_F != 10.0 || DIVCLK_DIVIDE != 1 ||
              CLKOUT0_DIVIDE_F != 20.0) $fatal(1, "Unsupported MMCM model ratio");
  always @(posedge CLKIN1 or posedge RST or posedge PWRDWN) begin
    if (RST || PWRDWN) begin CLKOUT0<=0; LOCKED<=0; lock_count<=0; end
    else begin
      CLKOUT0<=~CLKOUT0;
      if (lock_count<16) lock_count<=lock_count+1;
      else LOCKED<=1;
    end
  end
endmodule
