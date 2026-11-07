`timescale 1ns / 1ps
module tb_regfile;
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [3:0] req_i = 0, we_i = 0;
  logic [3:0][3:0] be_i = '1;
  logic [3:0][31:0] addr_i = 0, wdata_i = 0;
  wire [3:0] gnt_o, rvalid_o, error_o;
  wire [3:0][31:0] rdata_o;
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
  logic [2:0] gather_req_i = 0;
  logic [2:0][31:0] gather_addr_i = 0;
  wire [2:0] gather_gnt_o, gather_valid_o, gather_error_o;
  wire [2:0][31:0] gather_data_o;
  xbar #(
    .NUM_MASTERS(4)
  ) dut (
    .rf_sink_req_i   (1'b0),
    .rf_sink_addr_i  (32'b0),
    .rf_sink_wdata_i (32'b0),
    .rf_sink_gnt_o   (),
    .rf_sink_rvalid_o(),
    .rf_sink_error_o (),
    .*,
    .mmio_rdata_i    (32'h12345678),
    .mmio_error_i    (1'b0),
    .dm_rdata_i      (32'd0),
    .boot_rdata_i    (32'd0)
  );
  int checks = 0;
  task automatic check(input bit value, input string msg);
    if (!value) $fatal(1, "%s", msg);
    checks++;
  endtask
  task automatic access (input logic [31:0] address, data, input bit write, input logic [3:0] mask,
                         input bit expect_error = 0);
    @(negedge clk_i);
    req_i[0] = 1;
    we_i[0] = write;
    addr_i[0] = address;
    wdata_i[0] = data;
    be_i[0] = mask;
    #1;
    check(gnt_o[0], "Single request not granted");
    @(negedge clk_i);
    req_i[0] = 0;
    if (!rvalid_o[0]) @(negedge clk_i);
    check(rvalid_o[0] && error_o[0] == expect_error, "Bad response/error");
    if (!write && !expect_error) check(rdata_o[0] === data, "Read data mismatch");
    check(mem_req_o == 0, "Regfile transaction accessed SRAM");
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    // Two independent banks: two accepts and replies per cycle, no SRAM traffic.
    for (int i = 0; i < RF_BANK_WORDS; i++) begin
      @(negedge clk_i);
      req_i = 3;
      we_i = 3;
      addr_i[0] = RF_BASE + 32'(i * 4);
      addr_i[1] = RF_BASE + 32'(RF_BANK_WORDS * 4 + i * 4);
      wdata_i[0] = 32'(i) ^ 32'h12345678;
      wdata_i[1] = 32'(i) ^ 32'h89abcdef;
      #1;
      check(gnt_o[1:0] == 3 && mem_req_o == 0, "Dual-bank write grant");
      @(negedge clk_i);
      req_i = 0;
      check(rvalid_o[1:0] == 3, "Dual-bank write ack");
    end
    for (int i = 0; i < RF_BANK_WORDS; i++) begin
      @(negedge clk_i);
      req_i = 3;
      we_i = 0;
      addr_i[0] = RF_BASE + 32'(i * 4);
      addr_i[1] = RF_BASE + 32'(RF_BANK_WORDS * 4 + i * 4);
      #1;
      check(gnt_o[1:0] == 3, "Dual-bank read grant");
      @(negedge clk_i);
      req_i = 0;
      check(
          rvalid_o[1:0]==3 && rdata_o[0]==(32'(i)^32'h12345678)
          && rdata_o[1]==(32'(i)^32'h89abcdef),
          "Dual-bank payload");
    end
    access (RF_BASE, 32'hdeadbeef, 1, 4'b0101);
    access (RF_BASE, 32'h12ad56ef, 0, 15);
    // Payload survives system reset; only pending transactions/arbiters reset.
    @(negedge clk_i);
    rst_ni = 0;
    repeat (3) @(negedge clk_i);
    rst_ni = 1;
    access (RF_BASE, 32'h12ad56ef, 0, 15);
    access (RF_BASE + RF_BYTES, 0, 0, 15, 1);
    access (RF_BASE + 1, 0, 0, 15, 1);
    // A pending two-cycle MMIO reply blocks only its owner on the RF banks.
    @(negedge clk_i);
    req_i = 1;
    we_i = 0;
    addr_i[0] = 32'h40000000;
    #1;
    check(gnt_o[0], "MMIO grant");
    @(negedge clk_i);
    addr_i[0] = RF_BASE;
    req_i = 3;
    addr_i[1] = RF_BASE + RF_BANK_WORDS * 4;
    #1;
    check(!gnt_o[0] && gnt_o[1] && mmio_req_o, "Pending MMIO/RF owner exclusion");
    @(negedge clk_i);
    req_i[1] = 0;
    #1;
    check(rvalid_o[0] && rdata_o[0] == 32'h12345678 && rvalid_o[1] && gnt_o[0],
          "Parallel MMIO/RF replies");
    @(negedge clk_i);
    req_i = 0;
    check(rvalid_o[0] && rdata_o[0] == 32'h12ad56ef, "Deferred owner RF reply");
    // Same-bank contention is fair, with at most one winner per cycle.
    @(negedge clk_i);
    req_i = 15;
    we_i = 0;
    for (int m = 0; m < 4; m++) addr_i[m] = RF_BASE + 32'(m * 4);
    begin
      bit [3:0] seen;
      seen = 0;
      repeat (8) begin
        #1;
        check($countones(gnt_o) == 1, "RF bank granted twice");
        seen |= gnt_o;
        @(negedge clk_i);
      end
      check(seen == 15, "Regfile arbitration starved a master");
    end
    req_i = 0;
    repeat (3) @(negedge clk_i);
    // Banked compute interface: three independent words, not one 96-bit
    // contiguous address. Ordinary writes and gather reads see the same cells.
    for (int w = 0; w < 2 * RF_BANK_WORDS; w++)
    access (RF_BASE + 32'(w * 4), 32'h60000000 ^ 32'(w), 1, 15);
    @(negedge clk_i);
    gather_req_i = 7;
    gather_addr_i[0] = RF_BASE;
    gather_addr_i[1] = RF_BASE + 4;
    gather_addr_i[2] = RF_BASE + 8;
    repeat (8) begin
      #1;
      check(gather_gnt_o == 7, "Gather must accept 3 distinct banks in one cycle");
      @(negedge clk_i);
      check(gather_valid_o == 7 && gather_error_o == 0, "Gather throughput/ownership");
      for (int p = 0; p < 3; p++) check(gather_data_o[p] == (32'h60000000 ^ 32'(p)), "Gather data");
    end
    gather_req_i = 0;
    repeat (2) @(negedge clk_i);
    // Two ordinary reads plus three compute reads can coexist when all
    // five words occupy different physical banks (160 aggregate bits/cycle).
    req_i = 3;
    we_i = 0;
    addr_i[0] = RF_BASE + 12;
    addr_i[1] = RF_BASE + RF_BANK_WORDS * 4;
    gather_req_i = 7;
    #1;
    check(gnt_o == 3 && gather_gnt_o == 7, "Five-bank parallel grant");
    @(negedge clk_i);
    req_i = 0;
    gather_req_i = 0;
    check(rvalid_o == 3 && gather_valid_o == 7, "Five-bank parallel response");
    check(rdata_o[0] == 32'h60000003 && rdata_o[1] == (32'h60000000 ^ 32'(RF_BANK_WORDS)),
          "Parallel legacy data");
    for (int p = 0; p < 3; p++)
    check(gather_data_o[p] == (32'h60000000 ^ 32'(p)), "Parallel compute data");
    repeat (2) @(negedge clk_i);
    gather_req_i = 7;
    gather_addr_i[0] = RF_BASE;
    gather_addr_i[1] = RF_BASE;
    gather_addr_i[2] = RF_BASE;
    #1;
    check(gather_gnt_o == 7, "Same-word gather should broadcast one bank read");
    @(negedge clk_i);
    gather_req_i = 0;
    check(gather_valid_o == 7 && gather_error_o == 0, "Gather broadcast reply mask");
    for (int p = 0; p < 3; p++) check(gather_data_o[p] == 32'h60000000, "Gather broadcast payload");
    repeat (2) @(negedge clk_i);
    // Offsets 0,16,36 map to the same skewed physical bank. Persistent
    // conflicting lanes and an ordinary master must all make progress.
    begin
      logic [2:0] previous, seen;
      int legacy_grants, wide_grants;
      int word_index[3] = '{0, 4, 9};
      seen = 0;
      previous = 0;
      legacy_grants = 0;
      wide_grants = 0;
      gather_req_i = 7;
      for (int p = 0; p < 3; p++) gather_addr_i[p] = RF_BASE + 32'(word_index[p] * 4);
      req_i = 1;
      we_i = 0;
      addr_i[0] = RF_BASE;
      repeat (24) begin
        #1;
        check($countones(gather_gnt_o) + int'(gnt_o[0]) == 1, "Physical bank granted twice");
        previous = gather_gnt_o;
        seen |= previous;
        legacy_grants += int'(gnt_o[0]);
        wide_grants += $countones(previous);
        @(negedge clk_i);
        check(gather_valid_o == previous, "Conflict replay response mask");
        for (int p = 0; p < 3; p++)
        if (previous[p])
          check(gather_data_o[p] == (32'h60000000 ^ 32'(word_index[p])), "Conflict replay value");
      end
      check(seen == 7 && legacy_grants >= 8 && wide_grants >= 8, "Gather/legacy starvation");
    end
    req_i = 0;
    gather_req_i = 0;
    repeat (2) @(negedge clk_i);
    access (RF_BASE, 32'h00ab0000, 1, 4'b0100);
    @(negedge clk_i);
    gather_req_i = 7;
    gather_addr_i[0] = RF_BASE + RF_BYTES;
    gather_addr_i[1] = RF_BASE + 1;
    gather_addr_i[2] = RF_BASE;
    #1;
    check(gather_gnt_o == 7, "Invalid gather must complete, not hang");
    @(negedge clk_i);
    gather_req_i = 0;
    check(gather_valid_o == 7 && gather_error_o == 3, "Gather alignment/bounds errors");
    check(gather_data_o[2] == 32'h60ab0000, "Gather observes byte writes");
    @(negedge clk_i);
    rst_ni = 0;
    #1;
    check(gather_valid_o == 0 && gather_gnt_o == 0, "Reset drops gather metadata");
    repeat (2) @(negedge clk_i);
    rst_ni = 1;
    access (RF_BASE, 32'h60ab0000, 0, 15);
    $display(
        "RF GATHER PASS lanes=3 bits=32 physical_banks=8 peak_bits_per_cycle=96 aggregate_bits_per_cycle=160 checks=%0d conflicts, fairness, bytes, bounds, reset",
        checks);
    $display("REGFILE PASS bank_words=%0d checks=%0d dual-bank, bytes, bounds, reset, fairness",
             RF_BANK_WORDS, checks);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1, "RF timeout");
  end
endmodule
