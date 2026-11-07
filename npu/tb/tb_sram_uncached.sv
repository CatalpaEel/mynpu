`timescale 1ns / 1ps
// Compare the uncached xbar with the frozen cached baseline. Independent SRAM
// models receive different physical read counts but must expose identical bus
// grants, response cycles, errors and data for every accepted transaction.
module tb_sram_uncached;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [7:0] req_i = 0, we_i = 0;
  logic [7:0][3:0] be_i = '1;
  logic [7:0][31:0] addr_i = 0, wdata_i = 0;
  wire [7:0] gnt_o, rvalid_o, error_o, old_gnt, old_valid, old_error;
  wire [7:0][31:0] rdata_o, old_data;
  wire [1:0] mem_req_o, old_memreq;
  wire [1:0][3:0] mem_wen_o, old_wen;
  wire [1:0][10:0] mem_addr_o, old_addr;
  wire [1:0][31:0] mem_wdata_o, old_wdata;
  logic [1:0][31:0] mem_rdata_i = 0, old_rdata = 0;
  logic [31:0] memory[2][2048], old_memory[2][2048];
  wire [1:0][31:0] cache_hits_o, cache_misses_o, bank_accepts_o;
  wire [1:0][31:0] old_hits, old_misses, old_accepts;
  wire mmio_req_o, mmio_we_o, old_mmreq, old_mmwe;
  wire [11:0] mmio_addr_o, old_mmaddr;
  wire [31:0] mmio_wdata_o, old_mmdata;
  logic [31:0] mmio_rdata_i = 'h13579bdf, dm_rdata_i = 'habcde123, boot_rdata_i = 'h98765432;
  logic mmio_error_i = 0;
  xbar dut (
    .*,
    .rf_sink_req_i   (1'b0),
    .rf_sink_addr_i  (32'b0),
    .rf_sink_wdata_i (32'b0),
    .rf_sink_gnt_o   (),
    .rf_sink_rvalid_o(),
    .rf_sink_error_o (),
    .gather_req_i    (3'b0),
    .gather_addr_i   (96'b0),
    .gather_gnt_o    (),
    .gather_valid_o  (),
    .gather_error_o  (),
    .gather_data_o   (),
    .dm_req_o        (),
    .dm_we_o         (),
    .dm_be_o         (),
    .dm_addr_o       (),
    .dm_wdata_o      ()
  );
  xbar_cached_reference reference (
    .clk_i,
    .rst_ni,
    .req_i,
    .we_i,
    .be_i,
    .addr_i,
    .wdata_i,
    .gnt_o           (old_gnt),
    .rvalid_o        (old_valid),
    .error_o         (old_error),
    .rdata_o         (old_data),
    .mem_req_o       (old_memreq),
    .mem_wen_o       (old_wen),
    .mem_addr_o      (old_addr),
    .mem_wdata_o     (old_wdata),
    .mem_rdata_i     (old_rdata),
    .cache_hits_o    (old_hits),
    .cache_misses_o  (old_misses),
    .bank_accepts_o  (old_accepts),
    .mmio_req_o      (old_mmreq),
    .mmio_we_o       (old_mmwe),
    .mmio_addr_o     (old_mmaddr),
    .mmio_wdata_o    (old_mmdata),
    .mmio_rdata_i,
    .mmio_error_i,
    .dm_rdata_i,
    .boot_rdata_i,
    .rf_sink_req_i   (1'b0),
    .rf_sink_addr_i  (32'b0),
    .rf_sink_wdata_i (32'b0),
    .rf_sink_gnt_o   (),
    .rf_sink_rvalid_o(),
    .rf_sink_error_o (),
    .gather_req_i    (3'b0),
    .gather_addr_i   (96'b0),
    .gather_gnt_o    (),
    .gather_valid_o  (),
    .gather_error_o  (),
    .gather_data_o   (),
    .dm_req_o        (),
    .dm_we_o         (),
    .dm_be_o         (),
    .dm_addr_o       (),
    .dm_wdata_o      ()
  );
  int reads = 0, old_reads = 0, checks = 0, parallel = 0;
  always @(posedge clk_i) begin
    for (int b = 0; b < 2; b++) begin
      if (mem_req_o[b]) begin
        mem_rdata_i[b] <= memory[b][mem_addr_o[b]];
        if (mem_wen_o[b] == 0) reads++;
        for (int k = 0; k < 4; k++)
        if (mem_wen_o[b][k]) memory[b][mem_addr_o[b]][8*k+:8] <= mem_wdata_o[b][8*k+:8];
      end
      if (old_memreq[b]) begin
        old_rdata[b] <= old_memory[b][old_addr[b]];
        if (old_wen[b] == 0) old_reads++;
        for (int k = 0; k < 4; k++)
        if (old_wen[b][k]) old_memory[b][old_addr[b]][8*k+:8] <= old_wdata[b][8*k+:8];
      end
    end
  end
  initial begin
    for (int b = 0; b < 2; b++)
    for (int w = 0; w < 2048; w++) begin
      memory[b][w] = 'h75310000 ^ (32'(b) << 12) ^ 32'(w);
      old_memory[b][w] = memory[b][w];
    end
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int cycle = 0; cycle < 5000; cycle++) begin
      @(negedge clk_i);
      rst_ni = cycle % 997 != 0;
      mmio_rdata_i = $urandom;
      mmio_error_i = 1'($urandom);
      for (int m = 0; m < 8; m++) begin
        req_i[m] = $urandom_range(0, 3) != 0;
        we_i[m] = $urandom_range(0, 3) == 0;
        be_i[m] = 4'($urandom);
        wdata_i[m] = $urandom;
        addr_i[m] = 'h80000000 + 32'($urandom_range(0, 1) * 8192 + $urandom_range(0, 31) * 4);
        if (cycle % 11 == 0) addr_i[m] = 'h40000600 + 32'($urandom_range(0, 15) * 4);
        if (cycle % 17 == 0) addr_i[m] = 'h80;
        if (cycle % 23 == 0) begin
          addr_i[m] = 'h10000 + 32'($urandom_range(0, 15) * 4);
          we_i[m] = 0;
        end
        if (cycle % 31 == 0) addr_i[m] = 'h80000001;
        // A long read-only hot phase guarantees that the reference has hits.
        if (cycle % 200 < 80) begin
          req_i[m] = 1;
          we_i[m] = 0;
          addr_i[m] = 'h80000000 + 32'((m % 2) * 8192 + m * 4);
        end
      end
      #1;
      if (gnt_o !== old_gnt)
        $fatal(1, "Cached/uncached grants differ cycle=%0d %h/%h", cycle, gnt_o, old_gnt);
      for (int b = 0; b < 2; b++)
      if (old_memreq[b] && !mem_req_o[b]) $fatal(1, "Uncached path suppressed physical access");
      if (mem_req_o == 3) parallel++;
      @(posedge clk_i);
      #1;
      if (rvalid_o !== old_valid || error_o !== old_error)
        $fatal(1, "Cached/uncached response timing differs cycle=%0d", cycle);
      for (int m = 0; m < 8; m++)
      if (rvalid_o[m] && rdata_o[m] !== old_data[m])
        $fatal(
            1,
            "Cached/uncached response data differs cycle=%0d master=%0d got=%h want=%h",
            cycle,
            m,
            rdata_o[m],
            old_data[m]
        );
      if(mmio_req_o!==old_mmreq || (mmio_req_o && {mmio_we_o,mmio_addr_o,mmio_wdata_o}!=={old_mmwe,old_mmaddr,old_mmdata}))
        $fatal(1, "MMIO request changed");
      if (cache_hits_o !== 0) $fatal(1, "Cache hit state remains");
      checks++;
    end
    if (reads <= old_reads || parallel < 100) $fatal(1, "Insufficient hit/parallel coverage");
    $display(
        "SRAM UNCACHED PASS checks=%0d physical_reads=%0d cached_reference_reads=%0d dual_bank_cycles=%0d identical grants/responses/data",
        checks, reads, old_reads, parallel);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
