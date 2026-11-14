// Two independent 8KB single-port SRAM banks, with no transparent read cache.
// Every accepted SRAM request accesses its macro and replies next cycle.
// Software-managed shared RF is a separate address target.
module xbar #(
  parameter int GATHER_PORTS = 3,
  parameter int RF_SINK = 0,
  NUM_MASTERS = 8,
  ID_W = $clog2(NUM_MASTERS)
) (
  input logic clk_i,
  rst_ni,
  input logic [NUM_MASTERS-1:0] req_i,
  we_i,
  input logic [NUM_MASTERS-1:0][3:0] be_i,
  input logic [NUM_MASTERS-1:0][31:0] addr_i,
  wdata_i,
  output logic [NUM_MASTERS-1:0] gnt_o,
  rvalid_o,
  error_o,
  output logic [NUM_MASTERS-1:0][31:0] rdata_o,
  // Optional RF-only full-word store lane. It does not enter SRAM arbitration.
  input logic [3:0] rf_sink_be_i,
  input logic rf_sink_req_i,
  input logic [31:0] rf_sink_addr_i,
  rf_sink_wdata_i,
  output logic rf_sink_gnt_o,
  rf_sink_rvalid_o,
  rf_sink_error_o,
  input logic [GATHER_PORTS-1:0] gather_req_i,
  input logic [GATHER_PORTS-1:0][31:0] gather_addr_i,
  output logic [GATHER_PORTS-1:0] gather_gnt_o,
  gather_valid_o,
  gather_error_o,
  output logic [GATHER_PORTS-1:0][31:0] gather_data_o,
  output logic [1:0] mem_req_o,
  output logic [1:0][3:0] mem_wen_o,
  output logic [1:0][10:0] mem_addr_o,
  output logic [1:0][31:0] mem_wdata_o,
  input logic [1:0][31:0] mem_rdata_i,
  output logic mmio_req_o,
  mmio_we_o,
  output logic [11:0] mmio_addr_o,
  output logic [31:0] mmio_wdata_o,
  input logic [31:0] mmio_rdata_i,
  input logic mmio_error_i,
  output logic dm_req_o,
  dm_we_o,
  output logic [3:0] dm_be_o,
  output logic [31:0] dm_addr_o,
  dm_wdata_o,
  input logic [31:0] dm_rdata_i,
  boot_rdata_i,
  output logic [1:0][31:0] cache_hits_o,
  cache_misses_o,
  bank_accepts_o
);
  // SRAM address bit 13 selects a bank, bits 12:2 select its 32-bit word.
  // Each bank arbitrates independently; auxiliary MMIO/DM/boot uses a third
  // arbiter. One master can receive at most one response in a cycle.
  import npu_addr_pkg::*;
  localparam int RF_MASTERS = NUM_MASTERS + RF_SINK, RF_ID_W = $clog2(RF_MASTERS);
  logic [RF_MASTERS-1:0] rf_req, rf_we, rf_gnt, rf_valid;
  logic [RF_MASTERS-1:0][3:0] rf_be;
  logic [RF_MASTERS-1:0][31:0] rf_addr, rf_wdata, rf_data;
  assign rf_req[NUM_MASTERS-1:0] = req_i;
  assign rf_we[NUM_MASTERS-1:0] = we_i;
  assign rf_be[NUM_MASTERS-1:0] = be_i;
  assign rf_addr[NUM_MASTERS-1:0] = addr_i;
  assign rf_wdata[NUM_MASTERS-1:0] = wdata_i;
  if (RF_SINK) begin : g_rf_sink
    logic bad, bad_q;
    assign bad = rf_sink_req_i && (!is_rf_address(
        rf_sink_addr_i
    ) || rf_sink_addr_i[1:0] != 0) && rst_ni;
    assign rf_req[NUM_MASTERS] = rf_sink_req_i && !bad;
    assign rf_we[NUM_MASTERS] = 1;
    assign rf_be[NUM_MASTERS] = rf_sink_be_i;
    assign rf_addr[NUM_MASTERS] = rf_sink_addr_i;
    assign rf_wdata[NUM_MASTERS] = rf_sink_wdata_i;
    assign rf_sink_gnt_o = bad || rf_gnt[NUM_MASTERS];
    assign rf_sink_rvalid_o = bad_q || rf_valid[NUM_MASTERS];
    assign rf_sink_error_o = bad_q;
    always_ff @(posedge clk_i or negedge rst_ni)
      if (!rst_ni) bad_q <= 0;
      else bad_q <= bad;
  end else begin : g_no_rf_sink
    assign rf_sink_gnt_o = 0;
    assign rf_sink_rvalid_o = 0;
    assign rf_sink_error_o = 0;
  end
  logic [ID_W-1:0] rr[2], sel[2], owner[2], aux_rr, aux_sel, aux_owner;
  logic [1:0] found, valid_q, read_q;
  logic aux_found, aux_mmio, aux_dm, aux_boot, aux_dm_q, aux_valid, aux_pending, aux_error;
  logic [31:0] aux_data;
  logic [31:0] bank_accepts[2], sram_reads[2];
  logic [NUM_MASTERS-1:0] stream_req, stream_gnt, stream_valid;
  logic [NUM_MASTERS-1:0][31:0] stream_data;
  for (genvar m = 0; m < NUM_MASTERS; m++) begin
    assign stream_req[m] = req_i[m] && !(aux_pending && ID_W'(m) == aux_owner);
  end
  xbar_stream #(
    .MASTERS(NUM_MASTERS)
  ) i_stream_routes (
    .clk_i,
    .rst_ni,
    .req_i   (stream_req),
    .we_i,
    .be_i,
    .addr_i,
    .wdata_i,
    .gnt_o   (stream_gnt),
    .rvalid_o(stream_valid),
    .rdata_o (stream_data)
  );
  npu_data_regfile #(
    .GATHER_PORTS(GATHER_PORTS),
    .NUM_MASTERS (RF_MASTERS),
    .ID_W        (RF_ID_W)
  ) i_regfile (
    .clk_i,
    .rst_ni,
    .gather_req_i,
    .gather_addr_i,
    .gather_gnt_o,
    .gather_valid_o,
    .gather_error_o,
    .gather_data_o,
    .req_i           (rf_req),
    .we_i            (rf_we),
    .be_i            (rf_be),
    .addr_i          (rf_addr),
    .wdata_i         (rf_wdata),
    .exclude_i       (aux_pending),
    .excluded_owner_i(RF_ID_W'(aux_owner)),
    .gnt_o           (rf_gnt),
    .rvalid_o        (rf_valid),
    .rdata_o         (rf_data)
  );
  for (genvar b = 0; b < 2; b++) begin
    // Preserve diagnostic CSR addresses: hits are zero; former misses count
    // physical SRAM reads. No cache payload, tags, valid bits or hit state.
    assign cache_hits_o[b] = 0;
    assign cache_misses_o[b] = sram_reads[b];
    assign bank_accepts_o[b] = bank_accepts[b];
  end
  function automatic logic is_mem(input logic [31:0] a);
    return a[31:14] == 18'h20000 && a[1:0] == 0;
  endfunction
  logic [1:0][NUM_MASTERS-1:0] memory_candidates;
  logic [NUM_MASTERS-1:0] auxiliary_candidates;
  logic [1:0] memory_found;
  logic auxiliary_found;
  for (genvar m = 0; m < NUM_MASTERS; m++) begin : g_request_decode
    wire memory_address = is_mem(addr_i[m]);
    wire stream_address = is_stream_address(addr_i[m]) && addr_i[m][1:0] == 0;
    wire rf_address = is_rf_address(addr_i[m]) && addr_i[m][1:0] == 0;
    for (genvar b = 0; b < 2; b++)
      assign memory_candidates[b][m]=req_i[m] && !(aux_pending && ID_W'(m)==aux_owner) && memory_address && addr_i[m][13]==1'(b);
    assign auxiliary_candidates[m] = req_i[m] && !stream_address && !memory_address && !rf_address;
  end
  for (genvar b = 0; b < 2; b++) begin : g_memory_select
    npu_rr_select #(
      .N (NUM_MASTERS),
      .IW(ID_W)
    ) i_select (
      .req_i  (memory_candidates[b]),
      .first_i(rr[b]),
      .grant_o(),
      .valid_o(memory_found[b]),
      .index_o(sel[b])
    );
  end
  npu_rr_select #(
    .N (NUM_MASTERS),
    .IW(ID_W)
  ) i_auxiliary_select (
    .req_i  (auxiliary_candidates),
    .first_i(aux_rr),
    .grant_o(),
    .valid_o(auxiliary_found),
    .index_o(aux_sel)
  );
  always_comb begin
    gnt_o = rf_gnt[NUM_MASTERS-1:0] | stream_gnt;
    rvalid_o = rf_valid[NUM_MASTERS-1:0] | stream_valid;
    error_o = 0;
    rdata_o = rf_data[NUM_MASTERS-1:0];
    for (int m = 0; m < NUM_MASTERS; m++) if (stream_valid[m]) rdata_o[m] = stream_data[m];
    mem_req_o = 0;
    mem_wen_o = 0;
    mem_addr_o = 0;
    mem_wdata_o = 0;
    found = 0;
    for (int b = 0; b < 2; b++) begin
      // Only an outstanding auxiliary response blocks its owner.
      found[b] = memory_found[b] && rst_ni;
      if (found[b]) gnt_o[sel[b]] = 1;
      mem_req_o[b] = found[b];
      mem_wen_o[b] = be_i[sel[b]] & {4{we_i[sel[b]]}};
      mem_addr_o[b] = addr_i[sel[b]][12:2];
      mem_wdata_o[b] = wdata_i[sel[b]];
      if (valid_q[b]) begin
        rvalid_o[owner[b]] = 1;
        rdata_o[owner[b]] = read_q[b] ? mem_rdata_i[b] : 0;
      end
    end
    aux_found = auxiliary_found && rst_ni && !aux_pending;
    aux_mmio=addr_i[aux_sel][31:12]==20'h40000 && addr_i[aux_sel][1:0]==0 &&
    (aux_sel==0 || aux_sel==3) && (!we_i[aux_sel] || be_i[aux_sel]==15);
    aux_dm=addr_i[aux_sel][31:12]==0 && addr_i[aux_sel][1:0]==0 && (aux_sel==0 || aux_sel==3 || aux_sel==4);
    aux_boot=addr_i[aux_sel]>=32'h00010000 && addr_i[aux_sel]<32'h00010040 &&
    addr_i[aux_sel][1:0]==0 && !we_i[aux_sel] && (aux_sel==0 || aux_sel==3 || aux_sel==4);
    dm_req_o = aux_found && aux_dm;
    dm_we_o = we_i[aux_sel];
    dm_be_o = be_i[aux_sel];
    dm_addr_o = addr_i[aux_sel];
    dm_wdata_o = wdata_i[aux_sel];
    if (aux_found) gnt_o[aux_sel] = 1;
    mmio_req_o = aux_pending && rst_ni;
    if (aux_valid) begin
      rvalid_o[aux_owner] = 1;
      error_o[aux_owner] = aux_error;
      rdata_o[aux_owner] = aux_dm_q ? dm_rdata_i : aux_data;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 0;
      read_q <= 0;
      aux_dm_q <= 0;
      aux_rr <= 0;
      aux_owner <= 0;
      aux_valid <= 0;
      aux_pending <= 0;
      aux_error <= 0;
      aux_data <= 0;
      mmio_we_o <= 0;
      mmio_addr_o <= 0;
      mmio_wdata_o <= 0;
      for (int b = 0; b < 2; b++) begin
        rr[b] <= 0;
        owner[b] <= 0;
        bank_accepts[b] <= 0;
        sram_reads[b] <= 0;
      end
    end else begin
      for (int b = 0; b < 2; b++) begin
        valid_q[b] <= found[b];
        read_q[b] <= found[b] && !we_i[sel[b]];
        if (found[b]) begin
          owner[b] <= sel[b];
          rr[b] <= sel[b] == ID_W'(NUM_MASTERS - 1) ? 0 : sel[b] + 1'b1;
          bank_accepts[b] <= bank_accepts[b] + 1;
          if (!we_i[sel[b]]) sram_reads[b] <= sram_reads[b] + 1;
        end
      end
      // SRAM/DM/boot reply after one cycle. MMIO latches its request payload,
      // performs CSR access next cycle, then replies one cycle later. Only that
      // owner is excluded from SRAM arbitration while MMIO is pending.
      aux_valid <= aux_found && !aux_mmio;
      aux_pending <= 0;
      aux_dm_q <= aux_found && aux_dm;
      if (aux_pending) begin
        aux_valid <= 1;
        aux_error <= mmio_error_i;
        aux_data <= mmio_rdata_i;
      end
      if (aux_found) begin
        aux_owner <= aux_sel;
        aux_rr <= aux_sel == ID_W'(NUM_MASTERS - 1) ? 0 : aux_sel + 1'b1;
        aux_error <= !aux_mmio && !aux_dm && !aux_boot;
        aux_data <= aux_boot ? boot_rdata_i : 32'hdeadbeef;
        if (aux_mmio) begin
          aux_pending <= 1;
          mmio_we_o <= we_i[aux_sel];
          mmio_addr_o <= addr_i[aux_sel][11:0];
          mmio_wdata_o <= wdata_i[aux_sel];
        end
      end
    end
  end
endmodule
