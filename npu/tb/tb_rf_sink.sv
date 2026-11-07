`timescale 1ns / 1ps
module tb_rf_sink;
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [7:0] req_i = 0, we_i = 0;
  logic [7:0][3:0] be_i = '1;
  logic [7:0][31:0] addr_i = 0, wdata_i = 0;
  wire [7:0] gnt_o, rvalid_o, error_o;
  wire [7:0][31:0] rdata_o;
  logic rf_sink_req_i = 0;
  logic [31:0] rf_sink_addr_i = RF_BASE, rf_sink_wdata_i = 0;
  wire rf_sink_gnt_o, rf_sink_rvalid_o, rf_sink_error_o;
  logic [2:0] gather_req_i = 0;
  logic [2:0][31:0] gather_addr_i = 0;
  wire [2:0] gather_gnt_o, gather_valid_o, gather_error_o;
  wire [2:0][31:0] gather_data_o;
  wire [1:0] mem_req_o;
  wire [1:0][3:0] mem_wen_o;
  wire [1:0][10:0] mem_addr_o;
  wire [1:0][31:0] mem_wdata_o;
  logic [1:0][31:0] mem_rdata_i = 0;
  wire mmio_req_o, mmio_we_o, dm_req_o, dm_we_o;
  wire [11:0] mmio_addr_o;
  wire [31:0] mmio_wdata_o, dm_addr_o, dm_wdata_o;
  wire [3:0] dm_be_o;
  wire [1:0][31:0] cache_hits_o, cache_misses_o, bank_accepts_o;
  xbar #(
    .RF_SINK(1)
  ) dut (
    .rf_sink_be_i(4'hf),
    .*,
    .mmio_rdata_i(32'b0),
    .mmio_error_i(1'b0),
    .dm_rdata_i  (32'b0),
    .boot_rdata_i(32'b0)
  );
  always @(posedge clk_i)
    for (int bank = 0; bank < 2; bank++)
      if (mem_req_o[bank]) mem_rdata_i[bank] <= 32'h13579bdf;
  logic [31:0] reference_words[RF_BYTES/4];
  int checks = 0, overlap = 0, sink_grants = 0, gather_grants = 0, ordinary_grants = 0;
  task automatic tick;
    logic [7:0] granted;
    logic [2:0] gg;
    bit sg, bad;
    logic [2:0][31:0] expected;
    logic [31:0] ordinary;
    @(posedge clk_i);
    granted = gnt_o;
    gg = gather_gnt_o;
    sg = rf_sink_gnt_o;
    bad = rf_sink_req_i && (!is_rf_address(rf_sink_addr_i) || rf_sink_addr_i[1:0] != 0);
    for (int p = 0; p < 3; p++)
      if (gg[p]) expected[p] = reference_words[(gather_addr_i[p]-RF_BASE)/4];
    ordinary = reference_words[(addr_i[1]-RF_BASE)/4];
    // Same-bank reads and writes cannot both grant. Scoreboard reads precede
    // committing this edge's sink write, preserving the arbiter's ordering.
    if (sg && !bad) reference_words[(rf_sink_addr_i-RF_BASE)/4] = rf_sink_wdata_i;
    if (sg) sink_grants++;
    gather_grants += $countones(gg);
    if (granted[1]) ordinary_grants++;
    if (sg && granted[0]) overlap++;
    #1;
    if(rvalid_o!==granted || error_o!=0 || rf_sink_rvalid_o!==sg || rf_sink_error_o!==(sg && bad) || gather_valid_o!==gg || gather_error_o!=0)
      $fatal(1, "RF sink reply ownership/error");
    if (granted[0] && rdata_o[0] !== 32'h13579bdf) $fatal(1, "SRAM read corrupted");
    if (granted[1] && rdata_o[1] !== ordinary) $fatal(1, "Ordinary RF read corrupted");
    for (int p = 0; p < 3; p++)
      if (gg[p] && gather_data_o[p] !== expected[p]) $fatal(1, "RF gather ordering p=%0d", p);
    checks++;
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    addr_i[0] = 32'h80000000;
    addr_i[1] = RF_BASE;
    for (int w = 0; w < RF_BYTES / 4; w++) begin
      @(negedge clk_i);
      rf_sink_req_i = 1;
      rf_sink_addr_i = RF_BASE + 32'(w * 4);
      rf_sink_wdata_i = 32'hb0000000 + 32'(w);
      tick();
    end
    for (int n = 0; n < 800; n++) begin
      @(negedge clk_i);
      req_i = 3;
      rf_sink_req_i = 1;
      gather_req_i = 7;
      rf_sink_addr_i = RF_BASE + 32'((n % (RF_BYTES / 4)) * 4);
      rf_sink_wdata_i = 32'hca000000 ^ 32'(n);
      addr_i[1] = n % 2 ? rf_sink_addr_i : RF_BASE + 32'(((n + 11) % (RF_BYTES / 4)) * 4);
      for (int p = 0; p < 3; p++)
      gather_addr_i[p]=n%3==0 ? rf_sink_addr_i:RF_BASE+32'(((n+p*7)%(RF_BYTES/4))*4);
      tick();
    end
    @(negedge clk_i);
    req_i = 0;
    gather_req_i = 0;
    for (int n = 0; n < 3; n++) begin
      rf_sink_addr_i = n == 0 ? 32'h80000000 : n == 1 ? RF_BASE + 1 : RF_BASE + RF_BYTES;
      tick();
      @(negedge clk_i);
    end
    rf_sink_req_i = 0;
    rst_ni = 0;
    #1;
    if (rf_sink_gnt_o || rf_sink_rvalid_o) $fatal(1, "Reset leaked RF sink response");
    repeat (3) @(negedge clk_i);
    rst_ni = 1;
    tick();
    if (overlap < 100 || gather_grants < 100 || ordinary_grants < 50)
      $fatal(1, "Insufficient concurrent/fairness coverage");
    $display(
        "RF SINK PASS checks=%0d sram_store_overlap=%0d sink_grants=%0d gather_grants=%0d ordinary_grants=%0d ordering/fairness/invalid/reset",
        checks, overlap, sink_grants, gather_grants, ordinary_grants);
    $finish;
  end
endmodule
