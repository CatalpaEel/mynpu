`timescale 1ns / 1ps
module tb_xbar_stream;
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [5:0] req_i = 0, we_i = 0, gnt_o, rvalid_o;
  logic [5:0][3:0] be_i = 0;
  logic [5:0][31:0] addr_i = 0, wdata_i = 0, rdata_o;
  xbar_stream #(.MASTERS(6)) dut (.*);
  logic [31:0] model[4][8192];
  int head[4], tail[4], count[4], checks = 0, reads = 0, writes = 0;
  logic [5:0] expected_valid;
  logic [5:0][31:0] expected_data;
  int pops[4], pushes[4], bypasses = 0;
  initial begin
    for (int c = 0; c < 4; c++) begin
      head[c] = 0;
      tail[c] = 0;
      count[c] = 0;
    end
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int cycle = 0; cycle < 4000; cycle++) begin
      @(negedge clk_i);
      if (cycle == 2000) begin
        rst_ni = 0;
        req_i = 0;
        @(posedge clk_i);
        #1;
        if (rvalid_o || gnt_o) $fatal(1, "reset leaves replies");
        for (int c = 0; c < 4; c++) begin
          head[c] = 0;
          tail[c] = 0;
          count[c] = 0;
        end
        @(negedge clk_i);
        rst_ni = 1;
      end
      for (int m = 0; m < 6; m++) begin
        req_i[m] = $urandom_range(0, 3) != 0;
        we_i[m] = $urandom_range(0, 1);
        be_i[m] = 4'($urandom_range(1, 15));
        addr_i[m] = STREAM_BASE + ($urandom_range(0, 3) << 8) + ($urandom_range(0, 63) << 2);
        wdata_i[m] = $urandom;
      end
      // Force empty-read and full-write phases, then concurrent read/write.
      if (cycle < 24) begin
        req_i = 6'b1;
        we_i = 0;
        addr_i[0] = STREAM_BASE;
      end
      if (cycle >= 24 && cycle < 64) begin
        req_i = 6'b1;
        we_i = 6'b1;
        addr_i[0] = STREAM_BASE;
      end
      #1;
      expected_valid = gnt_o;
      expected_data = 0;
      for (int c = 0; c < 4; c++) begin
        pops[c] = 0;
        pushes[c] = 0;
      end
      // Buffered reads see the old queue head; empty reads require a granted writer.
      for (int m = 0; m < 6; m++)
      if (gnt_o[m]) begin
        int c;
        c = int'(addr_i[m][9:8]);
        if (!req_i[m]) $fatal(1, "grant without request");
        if (!we_i[m]) begin
          if (count[c] == 0) begin
            bit found;
            found = 0;
            for (int w = 0; w < 6; w++)
            if (gnt_o[w] && req_i[w] && we_i[w] && addr_i[w][9:8] == 2'(c)) begin
              found = 1;
              for (int b = 0; b < 4; b++)
              expected_data[m][8*b+:8] = be_i[w][b] ? wdata_i[w][8*b+:8] : 8'b0;
            end
            if (!found) $fatal(1, "empty read without producer");
            bypasses++;
          end else expected_data[m] = model[c][head[c]];
          head[c]++;
          pops[c]++;
          reads++;
        end
      end
      for (int m = 0; m < 6; m++)
      if (gnt_o[m] && we_i[m]) begin
        int c;
        c = int'(addr_i[m][9:8]);
        model[c][tail[c]] = 0;
        for (int b = 0; b < 4; b++) if (be_i[m][b]) model[c][tail[c]][8*b+:8] = wdata_i[m][8*b+:8];
        tail[c]++;
        pushes[c]++;
        writes++;
      end
      for (int c = 0; c < 4; c++) begin
        if (pops[c] > 1 || pushes[c] > 1) $fatal(1, "nonexclusive channel arbitration");
        count[c] += pushes[c] - pops[c];
        if (count[c] < 0 || count[c] > STREAM_FIFO_DEPTH) $fatal(1, "FIFO overflow/underflow");
      end
      @(posedge clk_i);
      #1;
      if (rvalid_o !== expected_valid) $fatal(1, "reply timing");
      for (int m = 0; m < 6; m++)
      if (expected_valid[m] && rdata_o[m] !== expected_data[m])
        $fatal(
            1,
            "FIFO data/order/byte mask cycle=%0d master=%0d got=%h want=%h",
            cycle,
            m,
            rdata_o[m],
            expected_data[m]
        );
      checks++;
    end
    if (bypasses == 0 || reads < 2000 || writes < 2000)
      $fatal(1, "insufficient concurrent traffic");
    $display("XBAR STREAM PASS checks=%0d reads=%0d writes=%0d bypasses=%0d", checks, reads,
             writes, bypasses);
    $finish;
  end
endmodule
