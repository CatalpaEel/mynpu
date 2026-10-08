`timescale 1ns/1ps

module my_npu_subsystem (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        req_i,
    input  logic        we_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o
);

  simple_npu_top i_npu_core (
      .clka  (clk_i),
      .wea   (we_i),
      .ena   (req_i),
      .addra (addr_i[13:2]),
      .dina  (wdata_i),
      .douta (rdata_o),
      .rst_ni(rst_ni)
  );

endmodule
