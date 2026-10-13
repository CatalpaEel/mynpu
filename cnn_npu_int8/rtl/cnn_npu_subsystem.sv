`timescale 1ns/1ps

// Drop-in companion to lab3's my_npu_subsystem.sv.  It intentionally lives in
// this separate project so the teaching lab remains unchanged.
module cnn_npu_subsystem #(
    parameter integer LANES       = 16,
    parameter integer SRAM_BYTES  = 16*1024,
    parameter integer MAX_LAYERS  = 8,
    parameter integer SHARED_SRAM = 1,
    parameter integer MEM_BACKEND  = 0,
    parameter MEM_INIT_FILE       = ""
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        req_i,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        irq_o
);
  generate
  if (MEM_BACKEND == 0) begin : g_functional
  cnn_npu_top #(
      .LANES(LANES), .SRAM_BYTES(SRAM_BYTES), .MAX_LAYERS(MAX_LAYERS),
      .SHARED_SRAM(SHARED_SRAM),
      .MEM_INIT_FILE(MEM_INIT_FILE)
  ) i_core (
      .clka(clk_i), .rst_ni(rst_ni), .ena(req_i), .wea(we_i), .be_i(be_i),
      .addra(addr_i[15:2]), .dina(wdata_i), .douta(rdata_o), .irq_o(irq_o)
  );
  end else if (LANES == 1) begin : g_single_port
  cnn_npu_sp_top #(
      .LANES(LANES), .SRAM_BYTES(SRAM_BYTES), .MAX_LAYERS(MAX_LAYERS),
      .SHARED_SRAM(SHARED_SRAM), .MEM_BACKEND(MEM_BACKEND),
      .MEM_INIT_FILE(MEM_INIT_FILE)
  ) i_core (
      .clka(clk_i), .rst_ni(rst_ni), .ena(req_i), .wea(we_i), .be_i(be_i),
      .addra(addr_i[15:2]), .dina(wdata_i), .douta(rdata_o), .irq_o(irq_o)
  );
  end else begin : g_multi_lane_single_port
  cnn_npu_sp_lanes #(
      .LANES(LANES), .SRAM_BYTES(SRAM_BYTES), .MAX_LAYERS(MAX_LAYERS),
      .SHARED_SRAM(SHARED_SRAM), .MEM_BACKEND(MEM_BACKEND),
      .MEM_INIT_FILE(MEM_INIT_FILE)
  ) i_core (
      .clka(clk_i), .rst_ni(rst_ni), .ena(req_i), .wea(we_i), .be_i(be_i),
      .addra(addr_i[15:2]), .dina(wdata_i), .douta(rdata_o), .irq_o(irq_o)
  );
  end
  endgenerate
endmodule
