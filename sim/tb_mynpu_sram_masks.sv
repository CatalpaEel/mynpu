`timescale 1ns/1ps

// Direct SRAM wrapper contract check: all byte write masks and the first,
// middle and last physical words. Compile with MEM_BACKEND=1 for FPGA BRAM or
// MEM_BACKEND=2 plus the private RA1SHD model for ASIC.
module tb_mynpu_sram_masks #(parameter integer MEM_BACKEND=1);
  logic clk=0, req=0, we=0;
  logic [3:0] be=0;
  logic [10:0] addr=0;
  logic [31:0] wdata=0, rdata;
  always #5 clk=~clk;

  generate
    if (MEM_BACKEND==1) begin : g_fpga
      mynpu_sram_2048x32_fpga mem(.clk_i(clk),.req_i(req),.we_i(we),.be_i(be),
                                  .addr_i(addr),.wdata_i(wdata),.rdata_o(rdata));
    end else begin : g_asic
      mynpu_sram_2048x32_asic mem(.clk_i(clk),.req_i(req),.we_i(we),.be_i(be),
                                  .addr_i(addr),.wdata_i(wdata),.rdata_o(rdata));
    end
  endgenerate

  task automatic write_word(input integer a, input logic [31:0] d, input logic [3:0] m);
    @(negedge clk); addr=a; wdata=d; be=m; we=1; req=1;
    @(posedge clk); @(negedge clk); req=0; we=0; be=0;
  endtask
  task automatic read_word(input integer a, output logic [31:0] d);
    @(negedge clk); addr=a; we=0; be=4'hf; req=1;
    @(posedge clk); #1 d=rdata; @(negedge clk); req=0;
  endtask

  initial begin
    logic [31:0] got, expected;
    integer addresses [0:2];
    addresses[0]=0; addresses[1]=1023; addresses[2]=2047;
    for (integer a=0;a<3;a++) begin
      write_word(addresses[a],32'h11223344,4'hf);
      read_word(addresses[a],got);
      if (got!==32'h11223344) $fatal(1,"SRAM base write mismatch addr=%0d got=%h",addresses[a],got);
      expected=32'h11223344;
      for (integer m=1;m<16;m++) begin
        write_word(addresses[a],32'ha5a5a5a5,m[3:0]);
        for (integer lane=0;lane<4;lane++)
          if (m[ lane ]) expected[lane*8 +: 8]=8'ha5;
        read_word(addresses[a],got);
        if (got!==expected) $fatal(1,"SRAM byte mask mismatch addr=%0d mask=%h got=%h ref=%h",addresses[a],m,got,expected);
      end
    end
    $display("[SRAM-MASKS] PASS backend=%0d all byte masks, first/middle/last words",MEM_BACKEND);
    $finish;
  end
endmodule
