`timescale 1ns / 1ps
module tb_xbar_concurrent;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [7:0] req_i = 0, we_i = 0, gnt_o, rvalid_o, error_o;
  logic [7:0][3:0] be_i = '1;
  logic [7:0][31:0] addr_i = '0, wdata_i = '0, rdata_o;
  logic [1:0] mem_req_o;
  logic [1:0][3:0] mem_wen_o;
  logic [1:0][10:0] mem_addr_o;
  logic [1:0][31:0] mem_wdata_o, mem_rdata_i = '0;
  logic mmio_req_o, mmio_we_o, mmio_error_i;
  logic [11:0] mmio_addr_o;
  logic [31:0] mmio_wdata_o, mmio_rdata_i;
  logic dm_req_o, dm_we_o;
  logic [3:0] dm_be_o;
  logic [31:0] dm_addr_o, dm_wdata_o;
  logic [31:0] dm_rdata_i = 32'hd00d0001, boot_rdata_i = 32'hb0071234;
  logic [1:0][31:0] cache_hits_o, cache_misses_o, bank_accepts_o;
  logic [2:0] gather_req_i = 0;
  logic [2:0][31:0] gather_addr_i = 0;
  wire [2:0] gather_gnt_o, gather_valid_o, gather_error_o;
  wire [2:0][31:0] gather_data_o;
  xbar dut (
    .rf_sink_req_i   (1'b0),
    .rf_sink_addr_i  (32'b0),
    .rf_sink_wdata_i (32'b0),
    .rf_sink_gnt_o   (),
    .rf_sink_rvalid_o(),
    .rf_sink_error_o (),
    .*
  );
  logic [31:0] mem[2][2048], reference_mem[2][2048];
  bit expected_valid[8][4], expected_error[8][4];
  logic [31:0] expected_data[8][4];
  int
      seed = 32'h71c0ffee,
      checks = 0,
      parallel_pending = 0,
      triple_grants = 0,
      owner_blocked = 0,
      grants = 0;
  assign mmio_error_i = mmio_req_o && mmio_addr_o[5];
  assign mmio_rdata_i = 32'hc5010000 ^ {20'b0, mmio_addr_o} ^ mmio_wdata_o;
  always @(posedge clk_i)
    for (int b = 0; b < 2; b++)
      if (mem_req_o[b]) begin
        mem_rdata_i[b] <= mem[b][mem_addr_o[b]];
        for (int k = 0; k < 4; k++)
        if (mem_wen_o[b][k]) mem[b][mem_addr_o[b]][k*8+:8] <= mem_wdata_o[b][k*8+:8];
      end
  initial begin
    logic [7:0] accepted, previous_accept;
    int slot, due, kind, bank, word, latency, chosen;
    logic [31:0] want;
    bit err, ram, mmio, dm, boot;
    void'($urandom(seed));
    for (int b = 0; b < 2; b++)
    for (int i = 0; i < 2048; i++) begin
      mem[b][i] = 32'hb0000000 | (32'(b) << 16) | 32'(i);
      reference_mem[b][i] = mem[b][i];
    end
    for (int m = 0; m < 8; m++) for (int j = 0; j < 4; j++) expected_valid[m][j] = 0;
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    previous_accept = '1;
    for (int t = 0; t < 2400; t++) begin
      @(negedge clk_i);
      if (t == 800 || t == 1600) begin
        rst_ni = 0;
        req_i = 0;
        repeat (3) @(negedge clk_i);
        rst_ni = 1;
        previous_accept = '1;
        for (int m = 0; m < 8; m++) for (int j = 0; j < 4; j++) expected_valid[m][j] = 0;
      end
      for (int m = 0; m < 8; m++)
      if (!req_i[m] || previous_accept[m]) begin
        req_i[m] = 1;
        kind = int'($urandom_range(0, 15));
        bank = int'($urandom_range(0, 1));
        word = int'($urandom_range(0, 63));
        addr_i[m] = 32'h80000000 + 32'(bank * 8192 + word * 4);
        we_i[m] = $urandom_range(0, 3) == 0;
        be_i[m] = 4'($urandom_range(0, 15));
        wdata_i[m] = $urandom;
        case (kind)
          0, 1, 2: begin
            addr_i[m] = 32'h40000000 + 32'(word * 4);
            be_i[m] = 15;
          end
          3: addr_i[m] = 32'h00000080;
          4: begin
            addr_i[m] = 32'h00010000 + 32'((word % 16) * 4);
            we_i[m] = 0;
          end
          5: addr_i[m] = npu_addr_pkg::RF_BASE + npu_addr_pkg::RF_BYTES;
          6: addr_i[m] = 32'h80000001;
          default: ;
        endcase
      end
      // Repeatedly force MMIO(owner3) -> SRAM(owner3) while both other banks run.
      if (t % 100 == 0 && previous_accept[3]) begin
        req_i[3] = 1;
        addr_i[3] = 32'h40000608;
        we_i[3] = 1;
        be_i[3] = 15;
      end
      @(posedge clk_i);
      accepted = gnt_o;
      previous_accept = accepted;
      slot = t % 4;
      if (dut.aux_pending) begin
        chosen = 0;
        for (int m = 0; m < 8; m++) begin
          if (accepted[m] && addr_i[m][31:14] == 18'h20000 && addr_i[m][1:0] == 0) chosen++;
        end
        if (chosen == 2) parallel_pending++;
        if(req_i[dut.aux_owner] && addr_i[dut.aux_owner][31:14]==18'h20000 && addr_i[dut.aux_owner][1:0]==0)begin
          owner_blocked++;
          if (accepted[dut.aux_owner])
            $fatal(1, "Same master accepted SRAM before delayed MMIO response");
        end
      end
      if ($countones(accepted) == 3) triple_grants++;
      for (int m = 0; m < 8; m++)
      if (accepted[m]) begin
        grants++;
        ram = addr_i[m][31:14] == 18'h20000 && addr_i[m][1:0] == 0;
        mmio=addr_i[m][31:12]==20'h40000 && addr_i[m][1:0]==0 && (m==0 || m==3) && (!we_i[m] || be_i[m]==15);
        dm = addr_i[m][31:12] == 0 && addr_i[m][1:0] == 0 && (m == 0 || m == 3 || m == 4);
        boot=addr_i[m]>=32'h10000 && addr_i[m]<32'h10040 && addr_i[m][1:0]==0 && !we_i[m] && (m==0 || m==3 || m==4);
        latency = mmio ? 2 : 1;
        due = (t + latency - 1) % 4;
        err = !(ram || mmio || dm || boot);
        if (expected_valid[m][due])
          $fatal(1, "Two responses scheduled on same master m=%0d cycle=%0d", m, t);
        want = 32'hdeadbeef;
        if (ram) begin
          bank = int'(addr_i[m][13]);
          word = int'(addr_i[m][12:2]);
          want = we_i[m] ? 0 : reference_mem[bank][word];
          if (we_i[m])
            for (int k = 0; k < 4; k++)
            if (be_i[m][k]) reference_mem[bank][word][k*8+:8] = wdata_i[m][k*8+:8];
        end else if (mmio) begin
          want = 32'hc5010000 ^ {20'b0, addr_i[m][11:0]} ^ wdata_i[m];
          err = addr_i[m][5];
        end else if (dm) want = dm_rdata_i;
        else if (boot) want = boot_rdata_i;
        expected_valid[m][due] = 1;
        expected_error[m][due] = err;
        expected_data[m][due] = want;
      end
      #1;
      for (int m = 0; m < 8; m++) begin
        if (rvalid_o[m] !== expected_valid[m][slot])
          $fatal(
              1,
              "Response valid m=%0d cycle=%0d got=%b expected=%b",
              m,
              t,
              rvalid_o[m],
              expected_valid[m][slot]
          );
        if (expected_valid[m][slot]) begin
          if (error_o[m] !== expected_error[m][slot] || rdata_o[m] !== expected_data[m][slot])
            $fatal(
                1,
                "Response m=%0d cycle=%0d data=%h expected=%h error=%b/%b",
                m,
                t,
                rdata_o[m],
                expected_data[m][slot],
                error_o[m],
                expected_error[m][slot]
            );
          checks++;
          expected_valid[m][slot] = 0;
        end
      end
    end
    // Cancel an explicitly outstanding registered MMIO request by reset.
    @(negedge clk_i);
    req_i = 0;
    we_i = 0;
    repeat (3) @(negedge clk_i);
    req_i = 8'h08;
    addr_i[3] = 32'h4000060c;
    we_i[3] = 1;
    be_i[3] = 15;
    wdata_i[3] = 32'h87654321;
    @(posedge clk_i);
    if (!gnt_o[3]) $fatal(1, "Reset test MMIO denied");
    grants++;
    #1;
    if (!mmio_req_o || rvalid_o[3]) $fatal(1, "Reset test did not enter delayed MMIO phase");
    @(negedge clk_i);
    rst_ni = 0;
    req_i = 0;
    we_i = 0;
    #1;
    if (mmio_req_o || gnt_o != 0 || rvalid_o != 0) $fatal(1, "Reset left a stale request/response");
    repeat (3) @(negedge clk_i);
    rst_ni = 1;
    repeat (3) begin
      @(posedge clk_i);
      #1;
      if (rvalid_o != 0 || mmio_req_o) $fatal(1, "Canceled MMIO reappeared after reset");
    end
    @(negedge clk_i);
    req_i = 8'h21;
    addr_i[0] = 32'h8000001c;
    addr_i[5] = 32'h80002020;
    @(posedge clk_i);
    if (gnt_o !== 8'h21) $fatal(1, "Both banks did not recover after reset");
    grants += 2;
    #1;
    if(rvalid_o!==8'h21 || error_o!=0 || rdata_o[0]!==reference_mem[0][7] || rdata_o[5]!==reference_mem[1][8])
      $fatal(1, "Post-reset data ownership mismatch");
    checks += 2;
    if (parallel_pending < 10 || triple_grants < 10 || owner_blocked < 10)
      $fatal(
          1,
          "Insufficient concurrency coverage parallel=%0d triple=%0d blocked=%0d",
          parallel_pending,
          triple_grants,
          owner_blocked
      );
    $display(
        "XBAR CONCURRENT PASS checks=%0d grants=%0d MMIO_pending_dual_bank=%0d triple_grants=%0d same_owner_blocks=%0d mixed SRAM/MMIO/DM/boot/errors byte writes direct SRAM and reset",
        checks, grants, parallel_pending, triple_grants, owner_blocked);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
