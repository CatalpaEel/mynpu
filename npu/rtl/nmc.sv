// Native arbiter. Default eight masters: CPU data, matrix, vector, host,
// CPU instruction, ingress DMA, egress DMA, copy/fill DMA.
// A grant accepts one request. SRAM responses return next cycle; MMIO
// requests execute through a register stage and respond in two cycles.
module nmc #(parameter int NUM_MASTERS = 8,
             parameter int ID_W = $clog2(NUM_MASTERS)) (
  input logic clk_i, rst_ni,
  input logic [NUM_MASTERS-1:0] req_i, we_i,
  input logic [NUM_MASTERS-1:0][3:0] be_i,
  input logic [NUM_MASTERS-1:0][31:0] addr_i, wdata_i,
  output logic [NUM_MASTERS-1:0] gnt_o, rvalid_o, error_o,
  output logic [NUM_MASTERS-1:0][31:0] rdata_o,
  output logic mem_req_o,
  output logic [3:0] mem_wen_o,
  output logic [10:0] mem_addr_o,
  output logic [31:0] mem_wdata_o,
  input logic [31:0] mem_rdata_i,
  output logic mmio_req_o, mmio_we_o,
  output logic [11:0] mmio_addr_o,
  output logic [31:0] mmio_wdata_o,
  input logic [31:0] mmio_rdata_i,
  input logic mmio_error_i
);
  logic [ID_W-1:0] rr_q, selected, owner_q;
  logic found, is_mem, is_mmio, valid_q, memory_q, error_q;
  logic [31:0] response_q;
  logic mmio_pending_q, mmio_we_q;
  logic [11:0] mmio_addr_q;
  logic [31:0] mmio_wdata_q;
  logic [ID_W-1:0] candidate;
  always_comb begin
    found = 1'b0;
    selected = rr_q;
    candidate = rr_q;
    for (int k = 0; k < NUM_MASTERS; k++) begin
      candidate = ID_W'((int'(rr_q) + k) % NUM_MASTERS);
      if (!found && req_i[candidate]) begin
        selected = candidate;
        found = 1'b1;
      end
    end
    // A one-cycle MMIO issue slot prevents response-owner collisions.
    if (mmio_pending_q) found = 1'b0;
    is_mem = addr_i[selected][31:13] == 19'h40000 && addr_i[selected][1:0] == 0;
    is_mmio = addr_i[selected][31:12] == 20'h40000 && addr_i[selected][1:0] == 0
              && (selected == 0 || selected == 3)
              && (!we_i[selected] || be_i[selected] == 4'hf);
    gnt_o = '0;
    if (found && rst_ni) gnt_o[selected] = 1'b1;
    mem_req_o = found && rst_ni && is_mem;
    mem_wen_o = be_i[selected] & {4{we_i[selected]}};
    mem_addr_o = addr_i[selected][12:2];
    mem_wdata_o = wdata_i[selected];
    mmio_req_o = mmio_pending_q && rst_ni;
    mmio_we_o = mmio_we_q;
    mmio_addr_o = mmio_addr_q;
    mmio_wdata_o = mmio_wdata_q;
    rvalid_o = '0;
    error_o = '0;
    rdata_o = '0;
    if (valid_q) begin
      rvalid_o[owner_q] = 1'b1;
      error_o[owner_q] = error_q;
      rdata_o[owner_q] = memory_q ? mem_rdata_i : response_q;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rr_q <= 0; owner_q <= 0; valid_q <= 0;
      memory_q <= 0; error_q <= 0; response_q <= 0;
      mmio_pending_q <= 0; mmio_we_q <= 0; mmio_addr_q <= 0; mmio_wdata_q <= 0;
    end else begin
      valid_q <= found && !is_mmio;
      mmio_pending_q <= 0;
      if (mmio_pending_q) begin
        valid_q <= 1;
        error_q <= mmio_error_i;
        response_q <= mmio_rdata_i;
      end
      if (found) begin
        owner_q <= selected;
        rr_q <= selected == ID_W'(NUM_MASTERS-1) ? '0 : selected + 1'b1;
        memory_q <= is_mem;
        error_q <= !is_mem && !is_mmio;
        response_q <= 32'hdeadbeef;
        if (is_mmio) begin
          mmio_pending_q <= 1;
          mmio_we_q <= we_i[selected];
          mmio_addr_q <= addr_i[selected][11:0];
          mmio_wdata_q <= wdata_i[selected];
        end
      end
    end
  end
endmodule
