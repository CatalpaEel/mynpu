`timescale 1ns / 1ps
module rf_equivalence_check #(
  parameter int G = 9,
  M = 7,
  IW = $clog2(M)
) (
  output logic done = 0
);
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [M-1:0] req_i = 0, we_i = 0;
  logic [M-1:0][3:0] be_i = '1;
  logic [M-1:0][31:0] addr_i = 0, wdata_i = 0;
  logic exclude_i = 0;
  logic [IW-1:0] excluded_owner_i = 0;
  logic [G-1:0] gather_req_i = 0;
  logic [G-1:0][31:0] gather_addr_i = 0;
  wire [M-1:0] gnt_o, rvalid_o, ref_gnt, ref_valid;
  wire [M-1:0][31:0] rdata_o, ref_data;
  wire [G-1:0] gather_gnt_o, gather_valid_o, gather_error_o, ref_ggnt, ref_gvalid, ref_gerror;
  wire [G-1:0][31:0] gather_data_o, ref_gdata;
  npu_data_regfile #(
    .GATHER_PORTS(G),
    .NUM_MASTERS (M),
    .ID_W        (IW)
  ) dut (
    .*
  );
  npu_data_regfile_reference #(
    .GATHER_PORTS(G),
    .NUM_MASTERS (M),
    .ID_W        (IW)
  ) reference (
    .gnt_o         (ref_gnt),
    .rvalid_o      (ref_valid),
    .rdata_o       (ref_data),
    .gather_gnt_o  (ref_ggnt),
    .gather_valid_o(ref_gvalid),
    .gather_error_o(ref_gerror),
    .gather_data_o (ref_gdata),
    .*
  );
  int checks = 0, broadcasts = 0, parallel_reads = 0;
  task automatic compare_grants;
    #1;
    if (gnt_o !== ref_gnt || gather_gnt_o !== ref_ggnt)
      $fatal(
          1,
          "RF grant mismatch G=%0d checks=%0d normal=%h/%h gather=%h/%h",
          G,
          checks,
          gnt_o,
          ref_gnt,
          gather_gnt_o,
          ref_ggnt
      );
  endtask
  task automatic compare_replies;
    #1;
    if(rvalid_o!==ref_valid || rdata_o!==ref_data || gather_valid_o!==ref_gvalid || gather_error_o!==ref_gerror || gather_data_o!==ref_gdata)
      $fatal(1, "RF reply mismatch G=%0d checks=%0d", G, checks);
    checks++;
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    // Initialize all logical words via the public write interface.
    for (int word = 0; word < 2 * RF_BANK_WORDS; word++) begin
      @(negedge clk_i);
      req_i = 1;
      we_i = 1;
      addr_i[0] = RF_BASE + 32'(word * 4);
      wdata_i[0] = 32'(word) ^ 'h76543210;
      compare_grants();
      @(posedge clk_i);
      compare_replies();
    end
    for (int cycle = 0; cycle < 5000; cycle++) begin
      @(negedge clk_i);
      rst_ni = cycle % 997 != 0;
      exclude_i = $urandom_range(0, 3) == 0;
      excluded_owner_i = IW'($urandom_range(0, M - 1));
      for (int m = 0; m < M; m++) begin
        req_i[m] = $urandom_range(0, 3) != 0;
        we_i[m] = 1'($urandom);
        be_i[m] = 4'($urandom);
        wdata_i[m] = $urandom;
        addr_i[m] = RF_BASE + 32'($urandom_range(0, 2 * RF_BANK_WORDS - 1) * 4);
        if (cycle % 13 == 0) addr_i[m] += 1;
        if (cycle % 17 == 0) addr_i[m] = 'h80000000;
      end
      for (int p = 0; p < G; p++) begin
        gather_req_i[p] = $urandom_range(0, 3) != 0;
        gather_addr_i[p] = RF_BASE + 32'($urandom_range(0, 2 * RF_BANK_WORDS - 1) * 4);
        if (cycle % 19 == 0) gather_addr_i[p] += 1;
        if (cycle % 23 == 0) gather_addr_i[p] = 'h80000000;
        if (cycle % 257 < 20) begin
          gather_req_i[p] = 1;
          gather_addr_i[p] = RF_BASE;
        end
      end
      compare_grants();
      if ($countones(gather_gnt_o) >= 2) parallel_reads++;
      if (cycle % 257 < 20 && (&gather_gnt_o)) broadcasts++;
      @(posedge clk_i);
      compare_replies();
    end
    if (parallel_reads == 0 || broadcasts == 0) $fatal(1, "Insufficient RF equivalence coverage");
    $display("RF EQUIVALENCE G=%0d M=%0d checks=%0d broadcasts=%0d parallel=%0d", G, M, checks,
             broadcasts, parallel_reads);
    done = 1;
  end
endmodule
module tb_rf_equivalence;
  wire [1:0] done;
  rf_equivalence_check #(
    .G(3),
    .M(4)
  ) a (
    done[0]
  );
  rf_equivalence_check #(
    .G(9),
    .M(7)
  ) b (
    done[1]
  );
  initial begin
    wait (&done);
    $display(
        "RF EQUIVALENCE PASS cycle-exact old/new grants, data, errors, reset, byte writes, broadcasts, exclusion");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
