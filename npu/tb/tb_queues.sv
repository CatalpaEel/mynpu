`timescale 1ns / 1ps
module tb_queues;
  logic clk_i = 0, rst_ni = 0, req_i = 0, we_i = 0;
  always #10 clk_i = ~clk_i;
  logic [11:0] addr_i = 0;
  logic [31:0] wdata_i = 0, rdata_o;
  logic error_o;
  logic mat_start_o, vec_start_o, mat_pending_o;
  logic [1:0][31:0] cache_hits_i = 0, cache_misses_i = 0, bank_accepts_i = 0;
  logic [31:0] mat_a_o, mat_b_o, mat_d_o, vec_a_o, vec_b_o, vec_d_o;
  logic [4:0] mat_m_o, mat_n_o, mat_flags_o;
  logic [8:0] mat_k_o;
  logic [12:0] vec_len_o;
  logic mat_precision_o;
  logic [1:0] mat_element_log2_o;
  logic [15:0] mat_lda_o, mat_ldb_o;
  logic [8:0] vec_op_o;
  logic [31:0] vec_scalar_o, vec_program_cfg_o;
  logic [15:0][31:0] vec_program_o;
  logic mat_busy_i, mat_done_i = 0, mat_fault_i = 0, mat_blocked_i;
  logic vec_busy_i, vec_done_i = 0, vec_fault_i = 0, run_engines = 0;
  logic [1:0] irq_o;
  logic [31:0] test_result_o, cpu_boot_addr_o;
  logic cpu_release_o;
  int mat_jobs = 0, vec_jobs = 0, mtimer = 0, vtimer = 0, checks = 0, md, vd;
  npu_mmio dut (.*);
  assign mat_busy_i = mtimer != 0;
  assign vec_busy_i = !run_engines || vtimer != 0;
  assign mat_blocked_i = !run_engines;
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      mat_done_i <= 0;
      vec_done_i <= 0;
      mtimer <= 0;
      vtimer <= 0;
    end else begin
      mat_done_i <= 0;
      vec_done_i <= 0;
      if (mat_start_o) begin
        if(mat_a_o!==32'h80000100+32'(mat_jobs*16) || mat_b_o!==32'h80002000+32'(mat_jobs*16) || mat_d_o!==32'h80000300+32'(mat_jobs*16) || mat_m_o!=1 || mat_n_o!=1 || mat_k_o!=1 || mat_flags_o!=(mat_jobs%md)%2 || mat_precision_o!=(mat_jobs%md)%2 || mat_element_log2_o!=((mat_jobs%md)%2 ? 1:0) || mat_lda_o!=mat_jobs%md+1 || mat_ldb_o!=mat_jobs%md+2)
          $fatal(1, "Matrix snapshot/order job=%0d", mat_jobs);
        mat_jobs++;
        checks++;
        mtimer <= 40;
      end else if (mtimer > 0) begin
        if (mtimer == 1) mat_done_i <= 1;
        mtimer <= mtimer - 1;
      end
      if (vec_start_o) begin
        if(vec_a_o!==32'h80001000+32'(vec_jobs*16) || vec_b_o!==32'h80002080+32'(vec_jobs*16) || vec_d_o!==32'h80001200+32'(vec_jobs*16) || vec_len_o!=4 || vec_op_o!==8'(vec_jobs%16) || vec_scalar_o!=123+vec_jobs)
          $fatal(1, "Vector snapshot/order job=%0d", vec_jobs);
        vec_jobs++;
        checks++;
        vtimer <= 80;
      end else if (vtimer > 0) begin
        if (vtimer == 1) vec_done_i <= 1;
        vtimer <= vtimer - 1;
      end
    end
  end
  task automatic write_reg(input logic [11:0] a, input logic [31:0] d, input bit err = 0);
    @(negedge clk_i);
    req_i = 1;
    we_i = 1;
    addr_i = a;
    wdata_i = d;
    #1;
    if (error_o !== err) $fatal(1, "CSR error a=%h got=%b expected=%b", a, error_o, err);
    checks++;
    @(negedge clk_i);
    req_i = 0;
    we_i = 0;
  endtask
  task automatic check_reg(input logic [11:0] a, input logic [31:0] d);
    @(negedge clk_i);
    addr_i = a;
    #1;
    if (rdata_o !== d) $fatal(1, "CSR data a=%h got=%h expected=%h", a, rdata_o, d);
    checks++;
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    addr_i = 'h124;
    #1;
    md = int'(rdata_o >> 16);
    addr_i = 'h224;
    #1;
    vd = int'(rdata_o >> 16);
    for (int round = 0; round < 2; round++) begin
      run_engines = 0;
      write_reg('h100, 2);
      write_reg('h200, 2);
      for (int j = 0; j < md; j++) begin
        write_reg('h108, 32'h80000100 + 32'((round * md + j) * 16));
        write_reg('h10c, 32'h80002000 + 32'((round * md + j) * 16));
        write_reg('h110, 32'h80000300 + 32'((round * md + j) * 16));
        write_reg('h114, 1);
        write_reg('h118, 1);
        write_reg('h11c, 1);
        write_reg('h130, j % 2);
        write_reg('h13c, j % 2);
        write_reg('h140, j % 2 ? 2 : 1);
        write_reg('h134, j + 1);
        write_reg('h138, j + 2);
        write_reg('h100, 1);
      end
      for (int j = 0; j < vd; j++) begin
        write_reg('h208, 32'h80001000 + 32'((round * vd + j) * 16));
        write_reg('h218, 32'h80002080 + 32'((round * vd + j) * 16));
        write_reg('h20c, 32'h80001200 + 32'((round * vd + j) * 16));
        write_reg('h210, 4);
        write_reg('h214, (round * vd + j) % 16);
        write_reg('h230, 123 + round * vd + j);
        write_reg('h200, 1);
      end
      // Leading dimensions must not change queued tasks.
      write_reg('h134, 144);
      write_reg('h138, 144);
      check_reg('h134, 144);
      check_reg('h138, 144);
      check_reg('h124, 32'(md << 16 | md));
      check_reg('h224, 32'(vd << 16 | vd));
      write_reg('h100, 1, 1);
      write_reg('h200, 1, 1);
      check_reg('h12c, 32'((round + 1) * md));
      check_reg('h22c, 32'((round + 1) * vd));
      write_reg('h108, 0);
      write_reg('h110, 0);
      write_reg('h208, 0);
      write_reg('h20c, 0);
      run_engines = 1;
      repeat ((md + vd) * 100 + 50) @(negedge clk_i);
      if (mat_jobs != (round + 1) * md || vec_jobs != (round + 1) * vd)
        $fatal(1, "Lost queued work");
      check_reg('h128, 32'(mat_jobs));
      check_reg('h228, 32'(vec_jobs));
      check_reg('h104, 6);
      check_reg('h204, 6);
    end
    write_reg('h100, 2);
    write_reg('h200, 2);
    check_reg('h104, 0);
    check_reg('h204, 0);
    write_reg('h100, 1);
    check_reg('h104, 4);
    check_reg('h12c, 32'(2 * md));
    // Program configuration is software-owned and remains writable while busy.
    check_reg('h03c, 32'h00020000);  // Two SRAM banks, zero cached words
    check_reg('h058, 32'h56504733);
    write_reg('h234, 32'h208);
    write_reg('h240, 32'h40db);
    check_reg('h234, 32'h208);
    check_reg('h240, 32'h40db);
    run_engines = 0;
    write_reg('h234, 1);
    write_reg('h240, 0);
    check_reg('h234, 1);
    check_reg('h240, 0);
    run_engines = 1;
    // Retired fused opcode must never silently run a different operation.
    write_reg('h208, 32'h80001000);
    write_reg('h20c, 32'h80001200);
    write_reg('h214, 16);
    write_reg('h200, 1);
    check_reg('h204, 4);
    check_reg('h22c, 32'(2 * vd));
    write_reg('h214, 0);
    // Reset must discard nonempty queues, not merely clear an idle status.
    run_engines = 0;
    write_reg('h108, 32'h80000100);
    write_reg('h10c, 32'h80002000);
    write_reg('h110, 32'h80000300);
    write_reg('h100, 1);
    write_reg('h208, 32'h80001000);
    write_reg('h218, 32'h80002080);
    write_reg('h20c, 32'h80001200);
    write_reg('h200, 1);
    @(negedge clk_i);
    rst_ni = 0;
    repeat (3) @(negedge clk_i);
    rst_ni = 1;
    run_engines = 1;
    check_reg('h124, 32'(md << 16));
    check_reg('h224, 32'(vd << 16));
    check_reg('h128, 0);
    check_reg('h228, 0);
    repeat (10) @(negedge clk_i);
    if (mat_jobs != 2 * md || vec_jobs != 2 * vd) $fatal(1, "reset replayed discarded work");
    // New format fields reject unsupported precision/spacing combinations.
    write_reg('h108, 'h80000100);
    write_reg('h10c, 'h80002000);
    write_reg('h110, 'h80000300);
    write_reg('h114, 1);
    write_reg('h118, 1);
    write_reg('h11c, 1);
    for (int invalid = 0; invalid < 4; invalid++) begin
      write_reg('h100, 2);
      write_reg('h130, invalid == 3 ? 8 : 0);
      write_reg('h13c, invalid == 0 ? 2 : invalid == 1 ? 1 : 0);
      write_reg('h140, invalid == 2 ? 3 : 1);
      write_reg('h100, 1);
      check_reg('h104, 4);
      check_reg('h12c, 0);
    end
    write_reg('h208, 'h80001000);
    write_reg('h20c, 'h80001200);
    write_reg('h210, 4);
    write_reg('h234, 1);
    write_reg('h240, 2);
    write_reg('h214, 'ha0);  // Old overloaded program/pack bit must not enqueue.
    write_reg('h200, 1);
    check_reg('h204, 4);
    check_reg('h22c, 0);
    if ($bits(dut.mq[0]) != 96 || $bits(dut.vq[0]) != 99) $fatal(1, "queue descriptor widths");
    $display(
        "QUEUES PASS matrix_depth=%0d vector_depth=%0d checks=%0d snapshots, wrap, overflow, concurrent engines, invalid descriptor, reset",
        md, vd, checks);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1, "queue timeout");
  end
endmodule
