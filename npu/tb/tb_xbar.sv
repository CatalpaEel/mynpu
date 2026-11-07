`timescale 1ns / 1ps
// Saturate all eight ports to verify fairness and response ownership each clock.
module tb_xbar;
  logic clk = 0, rst_n = 0;
  always #10 clk = ~clk;
  logic [7:0] req = '0, we = '0, gnt, valid, error;
  logic [7:0][3:0] be = '1;
  logic [7:0][31:0] addr, wdata = '0, rdata;
  logic [1:0] memreq;
  logic mmreq, mmwe;
  logic [1:0][3:0] memwen;
  logic [1:0][10:0] memaddr;
  logic [11:0] mmaddr;
  logic [1:0][31:0] memwdata, memrdata;
  logic [31:0] mmwdata;
  logic [31:0] memory[2][2048];
  int grant_counts[8] = '{default: 0};
  xbar dut (
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
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .req_i           (req),
    .we_i            (we),
    .be_i            (be),
    .addr_i          (addr),
    .wdata_i         (wdata),
    .gnt_o           (gnt),
    .rvalid_o        (valid),
    .error_o         (error),
    .rdata_o         (rdata),
    .mem_req_o       (memreq),
    .mem_wen_o       (memwen),
    .mem_addr_o      (memaddr),
    .mem_wdata_o     (memwdata),
    .mem_rdata_i     (memrdata),
    .mmio_req_o      (mmreq),
    .mmio_we_o       (mmwe),
    .mmio_addr_o     (mmaddr),
    .mmio_wdata_o    (mmwdata),
    .dm_req_o        (),
    .dm_we_o         (),
    .dm_be_o         (),
    .dm_addr_o       (),
    .dm_wdata_o      (),
    .dm_rdata_i      (32'b0),
    .boot_rdata_i    (32'b0),
    .mmio_rdata_i    (32'h12345678),
    .mmio_error_i    (1'b0)
  );
  initial
    for (int b = 0; b < 2; b++)
      for (int i = 0; i < 2048; i++) memory[b][i] = 32'hface0000 | (32'(b) << 12) | 32'(i);
  always @(posedge clk)
    for (int b = 0; b < 2; b++)
      if (memreq[b]) begin
        memrdata[b] <= memory[b][memaddr[b]];
        for (int k = 0; k < 4; k++)
        if (memwen[b][k]) memory[b][memaddr[b]][k*8+:8] <= memwdata[b][k*8+:8];
      end
  task automatic access (input int master, input bit wr, input logic [31:0] a, d,
                         input logic [3:0] mask, input logic [31:0] expected, input bit err = 0,
                         input int physical = -1);
    logic [1:0] requests;
    @(negedge clk);
    req = 1 << master;
    we = wr ? (1 << master) : 0;
    addr[master] = a;
    wdata[master] = d;
    be[master] = mask;
    do @(posedge clk); while (!gnt[master]);
    requests = memreq;
    #1;
    if (!valid[master] || error[master] !== err || (!wr && rdata[master] !== expected))
      $fatal(
          1, "XBAR access data/owner mismatch a=%h got=%h expected=%h", a, rdata[master], expected
      );
    if (physical >= 0 && requests !== 2'(physical))
      $fatal(1, "XBAR unexpected direct SRAM request a=%h req=%b", a, requests);
    @(negedge clk);
    req = 0;
    @(posedge clk);
    #1;
  endtask
  initial begin
    int owner;
    logic [7:0] accepted;
    for (int i = 0; i < 8; i++) addr[i] = 32'h80000000 + 32'(i * 4);
    repeat (5) @(negedge clk);
    rst_n = 1;
    req = 8'hff;
    for (int cycle = 0; cycle < 128; cycle++) begin
      @(posedge clk);
      accepted = gnt;
      owner = cycle % 8;
      if (accepted !== (8'b00000001 << owner))
        $fatal(1, "RR fairness failed cycle=%0d gnt=%b", cycle, gnt);
      #1;
      if (valid !== accepted || error !== 0) $fatal(1, "Pipelined response owner mismatch");
      if (rdata[owner] !== (32'hface0000 | 32'(owner))) $fatal(1, "Read data crossed masters");
      grant_counts[owner]++;
    end
    @(negedge clk);
    req = 0;
    @(posedge clk);
    #1;
    if (valid !== 0) $fatal(1, "Unexpected response without request");
    for (int i = 0; i < 8; i++) if (grant_counts[i] != 16) $fatal(1, "Unfair counts");
    $display("PASS XBAR: 128 consecutive grants/responses, all eight masters receive 16 grants");
    // Hold a competing SRAM request while a registered MMIO write executes.
    // Upstream payload changes must not alter the accepted MMIO command.
    @(negedge clk);
    req = 8'h08;
    we[3] = 1;
    addr[3] = 32'h40000608;
    wdata[3] = 32'h89abcdef;
    @(posedge clk);
    #1;
    if (valid !== 0 || !mmreq || !mmwe || mmaddr !== 12'h608 || mmwdata !== 32'h89abcdef)
      $fatal(1, "MMIO request stage/payload mismatch");
    @(negedge clk);
    req = 8'h20;
    we[3] = 0;
    addr[3] = 0;
    wdata[3] = 0;
    #1;
    if (gnt !== 8'h20 || mmaddr !== 12'h608 || mmwdata !== 32'h89abcdef)
      $fatal(1, "MMIO parallel SRAM grant or captured payload changed");
    @(posedge clk);
    #1;
    if(valid!==8'h28 || error!==0 || rdata[3]!==32'h12345678 || rdata[5]!==32'hface0005 || mmreq)
      $fatal(1, "MMIO response owner/data mismatch");
    @(posedge clk);
    #1;
    if (valid !== 8'h20 || error !== 0 || rdata[5] !== 32'hface0005)
      $fatal(1, "SRAM response after MMIO crossed masters");
    @(negedge clk);
    req = 0;
    $display(
        "PASS XBAR MMIO: registered payload, two-cycle response, parallel SRAM owner preserved");
    // Independent per-bank arbitration accepts two simultaneous transactions.
    @(negedge clk);
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int i = 0; i < 8; i++) addr[i] = 32'h80000000 + 32'((i % 2) * 8192 + i * 4);
    req = 8'hff;
    for (int cycle = 0; cycle < 128; cycle++) begin
      logic [7:0] expect_mask;
      int o0, o1;
      o0 = 2 * (cycle % 4);
      o1 = o0 + 1;
      expect_mask = (1 << o0) | (1 << o1);
      @(posedge clk);
      if (gnt !== expect_mask) $fatal(1, "Dual-bank fairness failed %b", gnt);
      #1;
      if(valid!==expect_mask || error!==0 || rdata[o0]!== (32'hface0000|32'(o0)) || rdata[o1]!== (32'hface1000|32'(o1)))
        $fatal(1, "Dual-bank data response crossed");
    end
    @(negedge clk);
    req = 0;
    @(posedge clk);
    #1;
    access (0, 0, 32'h80000000, 0, 15, 32'hface0000, 0, 1);  // Every SRAM read reaches its macro
    access (3, 1, 32'h80000000, 32'h123456aa, 1, 0, 0, 1);  // partial write updates SRAM
    access (4, 0, 32'h80000000, 0, 15, 32'hface00aa, 0, 1);
    access (5, 0, 32'h80000000, 0, 15, 32'hface00aa, 0, 1);  // Read-after-write from another master
    access (3, 0, npu_addr_pkg::RF_BASE + npu_addr_pkg::RF_BYTES, 0, 15, 32'hdeadbeef, 1, 0);
    access (3, 0, 32'h80000001, 0, 15, 32'hdeadbeef, 1, 0);
    // Consecutive reads and a newer write must preserve SRAM ordering.
    access (0, 0, 32'h80000040, 0, 15, 32'hface0010, 0, 1);
    @(negedge clk);
    req = 1;
    we = 0;
    addr[0] = 32'h80000000;
    @(posedge clk);
    if (!gnt[0] || !memreq[0]) $fatal(1, "Expected physical read");
    #1;
    @(negedge clk);
    req = 8'h08;
    we = 8'h08;
    addr[3] = 32'h80000000;
    wdata[3] = 32'h11223344;
    be[3] = 15;
    @(posedge clk);
    if (!gnt[3]) $fatal(1, "Write denied");
    #1;
    @(negedge clk);
    req = 0;
    we = 0;
    @(posedge clk);
    #1;
    access (1, 0, 32'h80000000, 0, 15, 32'h11223344, 0, 1);
    access (2, 0, 32'h80000000, 0, 15, 32'h11223344, 0, 1);
    // Reading/writing bank1 cannot corrupt the same word index in bank0.
    access (3, 1, 32'h80002000, 32'hcafef00d, 15, 0, 0, 2);
    access (6, 0, 32'h80002000, 0, 15, 32'hcafef00d, 0, 2);
    access (7, 0, 32'h80002000, 0, 15, 32'hcafef00d, 0, 2);
    access (1, 0, 32'h80000000, 0, 15, 32'h11223344, 0, 1);
    $display(
        "XBAR ALL PASS: 256 parallel grants, fairness, byte writes, read-after-write ordering, bounds, bank isolation");
    $finish;
  end
endmodule
