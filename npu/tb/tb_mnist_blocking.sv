`timescale 1ns / 1ps
// Observe the unchanged latency test from outside: no new DUT connections or
// stimulus. CPU bins partition each inference cycle; bus/event counts overlap.
`include "tb_mnist_latency.sv"
`define C tb.dut.i_core.i_cpu.core_i
`define B tb.dut.i_core
module tb_mnist_blocking;
  tb_mnist_latency tb ();
  int stage = 0, sample = 0;
  longint counts[7][13], software[7][7], events[7][19], pcs[4096];
  logic [2:0] pc_class[4096];
  logic [31:0] last_data_addr = 0;
  string map_path;
  string names[13] = '{
      "cycles",
      "reset_boot",
      "wfi",
      "lsu_sram",
      "lsu_mmio",
      "lsu_rf",
      "lsu_fifo",
      "lsu_other",
      "fetch",
      "load_hazard",
      "jump_hazard",
      "pipeline",
      "other_awake"
  };
  string sw_names[7] = '{
      "queue_poll",
      "completion_poll",
      "ack_poll",
      "work",
      "front_end",
      "wfi",
      "reset_boot"
  };
  string ev_names[19] = '{
      "instructions",
      "instr_grant_wait",
      "instr_responses",
      "data_grant_wait",
      "data_responses",
      "cnn_sram_wait",
      "cnn_fifo_wait",
      "cnn_rf_wait",
      "cnn_rf_sink_wait",
      "matrix_req_wait",
      "vector_req_wait",
      "vector_a_req",
      "vector_a_wait",
      "matrix_mac_steps",
      "matrix_mac_blocked",
      "quant_active",
      "quant_output_blocked",
      "cnn_wait_instr_bank",
      "cnn_wait_data_bank"
  };
  initial begin
    for (int i = 0; i < 4096; i++) pc_class[i] = 0;
    if (!$value$plusargs("block_pc_map=%s", map_path)) $fatal(1, "Missing PC map");
    $readmemh(map_path, pc_class);
  end
  always @(posedge tb.profile_enable) begin
    stage = 0;
    for (int s = 0; s < 7; s++) begin
      for (int n = 0; n < 13; n++) counts[s][n] = 0;
      for (int n = 0; n < 7; n++) software[s][n] = 0;
      for (int n = 0; n < 19; n++) events[s][n] = 0;
    end
    for (int p = 0; p < 4096; p++) pcs[p] = 0;
  end
  always @(posedge tb.clk) begin
    if (`B.req[0] && `B.gnt[0]) last_data_addr = `B.addr[0];
    if (tb.measure && tb.profile_enable) begin
      int reason, category, pc;
      logic [31:0] a;
      reason = 12;
      a = `B.req[0] ? `B.addr[0] : last_data_addr;
      if (!`B.cpu_rst_n) reason = 1;
      else if (`C.core_sleep_o) reason = 2;
      else if (!`C.lsu_ready_ex || !`C.lsu_ready_wb) begin
        if (a[31:14] == 18'h20000) reason = 3;
        else if (a[31:12] == 20'h40000) reason = 4;
        else if (npu_addr_pkg::is_rf_address(a)) reason = 5;
        else if (npu_addr_pkg::is_stream_address(a)) reason = 6;
        else reason = 7;
      end else if (`C.perf_imiss) reason = 8;
      else if (`C.id_stage_i.load_stall) reason = 9;
      else if (`C.id_stage_i.jr_stall) reason = 10;
      else if (!`C.id_ready) reason = 11;
      counts[stage][0]++;
      counts[stage][reason]++;
      category = 4;
      pc = int'((`C.pc_id - 32'h80000000) >> 2);
      if (reason == 1) category = 6;
      else if (reason == 2) category = 5;
      else if (`C.instr_valid_id && pc >= 0 && pc < 4096) begin
        category = pc_class[pc] == 0 ? 3 : int'(pc_class[pc]) - 1;
        pcs[pc]++;
      end
      software[stage][category]++;
      // Combinational predicate used by the CPU's own MINSTRET event. Do not
      // count a registered event held high while the CPU clock is gated.
      if (!`C.core_sleep_o && `C.id_stage_i.minstret) events[stage][0]++;
      if (`B.req[4] && !`B.gnt[4]) events[stage][1]++;
      if (`B.rvalid[4]) events[stage][2]++;
      if (`B.req[0] && !`B.gnt[0]) events[stage][3]++;
      if (`B.rvalid[0]) events[stage][4]++;
      if (`B.req[1] && !`B.gnt[1]) begin
        a = `B.addr[1];
        if (a[31:14] == 18'h20000) begin
          events[stage][5]++;
          if (`B.req[4] && `B.gnt[4] && `B.addr[4][31:14] == 18'h20000 && `B.addr[4][13] == a[13])
            events[stage][17]++;
          if (`B.req[0] && `B.gnt[0] && `B.addr[0][31:14] == 18'h20000 && `B.addr[0][13] == a[13])
            events[stage][18]++;
        end else if (npu_addr_pkg::is_stream_address(a)) events[stage][6]++;
        else if (npu_addr_pkg::is_rf_address(a)) events[stage][7]++;
      end
      if (`B.cnn_rf_sink_req && !`B.cnn_rf_sink_gnt) events[stage][8]++;
      // Matrix's ordinary master is 5; master 1 belongs to CNN.
      if (`B.req[5] && !`B.gnt[5]) events[stage][9]++;
      if (`B.req[2] && !`B.gnt[2]) events[stage][10]++;
      if (`B.i_vector_stream.state == `B.i_vector_stream.A_REQ) events[stage][11]++;
      if (`B.i_vector_stream.state == `B.i_vector_stream.A_WAIT) events[stage][12]++;
      if (`B.matrix_compute_valid && `B.matrix_compute_multiply) begin
        if (`B.matrix_compute_ready) events[stage][13]++;
        else events[stage][14]++;
      end
      if (`B.i_quant.state != 0) events[stage][15]++;
      if (|(`B.i_quant.valid_o & ~`B.i_quant.ready_i)) events[stage][16]++;
      if (`B.req[0] && `B.gnt[0] && `B.we[0] && `B.addr[0] == 32'h80001f04) begin
        if (`B.wdata[0] != 32'(stage + 1) || stage >= 6) $fatal(1, "Bad blocking stage");
        stage++;
      end
    end
  end
  always @(negedge tb.profile_enable) begin
    longint total, partition, sw_total;
    total = 0;
    for (int s = 0; s < 7; s++) begin
      partition = 0;
      sw_total = 0;
      for (int n = 1; n < 13; n++) partition += counts[s][n];
      for (int n = 0; n < 7; n++) sw_total += software[s][n];
      if (partition != counts[s][0] || sw_total != counts[s][0]) $fatal(1, "Blocking partition");
      total += counts[s][0];
      $write("CPU_BLOCK_PROFILE sample=%0d stage=%0d", sample, s);
      for (int n = 0; n < 13; n++) $write(" %s=%0d", names[n], counts[s][n]);
      $write("\nCPU_SOFTWARE_PROFILE sample=%0d stage=%0d", sample, s);
      for (int n = 0; n < 7; n++) $write(" %s=%0d", sw_names[n], software[s][n]);
      $write("\nBUS_BLOCK_PROFILE sample=%0d stage=%0d", sample, s);
      for (int n = 0; n < 19; n++) $write(" %s=%0d", ev_names[n], events[s][n]);
      $write("\n");
    end
    if (total != tb.elapsed || stage != 6)
      $fatal(1, "Blocking elapsed mismatch %0d/%0d stage=%0d", total, tb.elapsed, stage);
    for (int p = 0; p < 4096; p++)
    if (pcs[p] != 0)
      $display("PC_PROFILE sample=%0d pc=%h cycles=%0d", sample, 32'h80000000 + 32'(p * 4), pcs[p]);
    $display("BLOCKING PASS sample=%0d cycles=%0d", sample, total);
    sample ++;
  end
endmodule
`undef C
`undef B
