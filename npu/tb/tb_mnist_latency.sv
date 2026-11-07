`timescale 1ns / 1ps
module tb_mnist_latency;
  logic clk = 0;
  always #10 clk = ~clk;
  logic rst_n = 0, cpu_run = 1;
  logic hreq = 0, hwe = 0;
  logic [3:0] hbe = 4'hf;
  logic [31:0] haddr = 0, hwdata = 0;
  wire hgnt, hrvalid, herror;
  wire [31:0] hrdata;
  wire [4:0] irq;
  logic rx_valid = 0, rx_last = 0, tx_ready = 0;
  logic [31:0] rx_data = 0;
  logic [3:0] rx_keep = 4'hf;
  wire rx_ready, rx_abort, tx_valid, tx_last, tx_abort;
  wire [31:0] tx_data;
  wire [3:0] tx_keep;
  logic [31:0] boot_image[0:511];
  wire cpu_done, cpu_pass;
  localparam logic [31:0] SRAM = 32'h80000000, MMIO = 32'h40000000;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (cpu_run),
    .tck_i             (1'b0),
    .tms_i             (1'b1),
    .td_i              (1'b0),
    .td_o              (),
    .cpu_debug_halted_o(),
    .host_req_i        (hreq),
    .host_we_i         (hwe),
    .host_be_i         (hbe),
    .host_addr_i       (haddr),
    .host_wdata_i      (hwdata),
    .host_gnt_o        (hgnt),












    .host_rvalid_o  (hrvalid),
    .host_error_o   (herror),
    .host_rdata_o   (hrdata),
    .irq_o          (irq),
    .cpu_test_done_o(cpu_done),
    .cpu_test_pass_o(cpu_pass)
  );
  int checks = 0, transactions = 0, mat_jobs = 0;
  int max_host_wait = 0;
  int rx_aborts = 0, tx_aborts = 0;
  task automatic transfer(input bit wr, input logic [31:0] a, d, input logic [3:0] mask,
                          input bit expected_error, output logic [31:0] result);
    int waited;
    @(negedge clk);
    hreq = 1;
    hwe = wr;
    haddr = a;
    hwdata = d;
    hbe = mask;
    waited = 0;
    do begin
      @(posedge clk);
      waited++;
      if (waited > 16) $fatal(1, "Host starved, addr=%h", a);
    end while (!hgnt);
    if (waited > max_host_wait) max_host_wait = waited;
    @(negedge clk);
    hreq = 0;
    if (!hrvalid) @(negedge clk);  // Registered MMIO responds one cycle after SRAM.
    if (!hrvalid) $fatal(1, "Missing response addr=%h", a);
    if (herror !== expected_error)
      $fatal(1, "Bus error addr=%h got=%b expected=%b", a, herror, expected_error);
    result = hrdata;
    transactions++;
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    transfer(1, a, d, 4'hf, 0, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    transfer(0, a, 0, 4'hf, 0, d);
  endtask
  task automatic expect_word(input logic [31:0] a, d);
    logic [31:0] got;
    rd(a, got);
    if (got !== d) $fatal(1, "Mismatch addr=%h got=%h expected=%h", a, got, d);
    checks++;
  endtask
  task automatic wait_unit(input logic [31:0] status_addr, input bit allow_error = 0);
    logic [31:0] s;
    bit finished;
    finished = 0;
    for (int t = 0; t < 40000 && !finished; t++) begin
      rd(status_addr, s);
      if (s[2] && !allow_error) $fatal(1, "Unexpected command error status=%h", s);
      finished = s[1] && !s[0];
    end
    if (!finished) $fatal(1, "Unit timeout %h", status_addr);
    checks++;
  endtask

  `include "test_meta.svh"
  logic [7:0] payload[8192];
  logic [7:0] golden[784];
  // Test-only preload; actual pin-level loading is covered by tb_jtag SBA.
  task automatic host_load(input string filename, input int count, input logic [31:0] destination);
    logic [31:0] word, ignored;
    logic [3:0] keep;
    $readmemh(filename, payload, 0, count - 1);
    for (int i = 0; i < count; i += 4) begin
      word = 0;
      keep = 0;
      for (int b = 0; b < 4 && i + b < count; b++) begin
        word[b*8+:8] = payload[i+b];
        keep[b] = 1;
      end
      transfer(1, destination + i, word, keep, 0, ignored);
    end
  endtask
  bit measure = 0;
  longint elapsed = 0, kernel = 0, macs = 0;
  int jobs = 0, queue_peak = 0, pack_peak = 0;
  int
      weight_reads = 0,
      act_reads = 0,
      quant_reads = 0,
      output_words = 0,
      request_stalls = 0,
      tile_waits = 0;
  int
      gather_words = 0,
      gather_cycles = 0,
      gather_parallel = 0,
      gather_peak = 0,
      gather_distinct_three = 0,
      gather_conflicts = 0;
  bit previous_busy = 0;
  always @(posedge clk) begin
    if (measure) begin
      elapsed++;
`ifndef NPU_GATE_SIM
      begin
        int lanes;
        lanes = $countones(dut.i_core.cnn_gather_req & dut.i_core.cnn_gather_gnt);
        gather_words += lanes;
        if (lanes != 0) gather_cycles++;
        if (lanes > 1) gather_parallel++;
        if (lanes > gather_peak) gather_peak = lanes;
        if (|(dut.i_core.cnn_gather_req & ~dut.i_core.cnn_gather_gnt)) gather_conflicts++;
        if (lanes==3 && dut.i_core.cnn_gather_addr[0]!=dut.i_core.cnn_gather_addr[1] &&
            dut.i_core.cnn_gather_addr[0]!=dut.i_core.cnn_gather_addr[2] &&
            dut.i_core.cnn_gather_addr[1]!=dut.i_core.cnn_gather_addr[2])
          gather_distinct_three++;
      end
      if (dut.i_core.i_stream.req_o && !dut.i_core.i_stream.gnt_i) request_stalls++;
      if (dut.i_core.i_stream.events.waiting) tile_waits++;
      if (dut.i_core.i_stream.req_o && dut.i_core.i_stream.gnt_i && dut.i_core.i_stream.we_o)
        output_words++;
      if(dut.i_core.i_stream.req_o && dut.i_core.i_stream.gnt_i && !dut.i_core.i_stream.we_o && dut.i_core.i_stream.i_engine.load_state==dut.i_core.i_stream.i_engine.WREQ)
        weight_reads++;
      if(dut.i_core.i_stream.req_o && dut.i_core.i_stream.gnt_i && !dut.i_core.i_stream.we_o && dut.i_core.i_stream.i_engine.load_state==dut.i_core.i_stream.i_engine.AREQ)
        act_reads++;


      if (int'(dut.i_core.i_stream.i_control.qcount) > queue_peak)
        queue_peak = int'(dut.i_core.i_stream.i_control.qcount);
      if (int'(dut.i_core.i_stream.i_engine.mac_result_valid_i) > pack_peak)
        pack_peak = int'(dut.i_core.i_stream.i_engine.mac_result_valid_i);
      if (dut.i_core.i_stream.events.busy) kernel++;
      if (dut.i_core.i_stream.i_engine.tap_valid) macs += dut.i_core.i_stream.i_engine.tap_count;
      if (previous_busy && !dut.i_core.cnn_busy) jobs++;
      previous_busy = dut.i_core.cnn_busy;
`endif
    end
  end
`ifndef NPU_GATE_SIM
  `include "mnist_profile.svh"
`endif
  initial begin
    logic [31:0] value;
    int limit, max_cycles, ignored, samples;
    longint ingress_cycles, total_cycles;
    samples = 10;
    ignored = $value$plusargs("samples=%d", samples);
    if (samples < 1 || samples > 10) $fatal(1, "samples must be in 1..10");
    max_cycles = 0;
    ignored = $value$plusargs("max_cycles=%d", max_cycles);
    for (int sample = 0; sample < samples; sample ++) begin
      measure = 0;
      @(negedge clk);
      rst_n = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      host_load("boot.hex", PROGRAM_BYTES, SRAM);
      host_load("params.hex", PARAM_BYTES, SRAM + 'h2000);
      wr(SRAM + 'h1f00, 32'hffffffff);
      wr(SRAM + 'h1f04, 0);
      wr(SRAM + 'h1f08, 0);
      wr(SRAM + 'h1f0c, 0);
      elapsed = 0;
      kernel = 0;
      macs = 0;
      jobs = 0;
      weight_reads = 0;
      act_reads = 0;
      quant_reads = 0;
      output_words = 0;
      request_stalls = 0;
      tile_waits = 0;
      queue_peak = 0;
      pack_peak = 0;
      previous_busy = 0;
      gather_words = 0;
      gather_cycles = 0;
      gather_parallel = 0;
      gather_peak = 0;
      gather_distinct_three = 0;
      gather_conflicts = 0;
      measure = 1;
      host_load($sformatf("input%0d.hex", sample), 784, SRAM + 'h1400);
      ingress_cycles = elapsed;
`ifndef NPU_GATE_SIM
      profile_begin();
`endif
      wr(MMIO + 8, 1);
      limit = 0;
      // No host polling, per-layer ACK or competing host traffic during inference.
      while (!cpu_done) begin
        @(negedge clk);
        limit++;
        if (limit > 100000) $fatal(1, "Single inference timeout");
      end
      measure = 0;
      total_cycles = elapsed;
      elapsed -= ingress_cycles;
`ifndef NPU_GATE_SIM
      profile_finish(sample, elapsed);
`endif
      if (max_cycles > 0 && elapsed >= max_cycles)
        $fatal(1, "Inference exceeds cycle limit got=%0d limit=%0d", elapsed, max_cycles);
      if (!cpu_pass) $fatal(1, "CPU failed");
`ifndef NPU_GATE_SIM
      if (!cpu_pass || dut.i_core.i_stream.i_control.completed != STREAM_TASKS || macs != 39330 || dut.i_core.i_mmio.mat_completed != 90)
        $fatal(1, "Single accounting/result failed jobs=%0d macs=%0d", jobs, macs);
`endif
      expect_word(SRAM + 'h1f00, prediction[sample]);
      expect_word(SRAM + 'h1f04, 6);
      $readmemh($sformatf("gold%0d_5.hex", sample), golden, 0, 9);
      for (int i = 0; i < 10; i += 4) begin
        rd(SRAM + 'h1400 + 32'(i), value);
        for (int b = 0; b < 4 && i + b < 10; b++) begin
          if (value[b*8+:8] !== golden[i+b])
            $fatal(1, "Single logits mismatch sample=%0d element=%0d", sample, i + b);
          checks++;
        end
      end
`ifndef NPU_GATE_SIM
      $display(
          "MEMORY_PROFILE sample=%0d weight_reads=%0d activation_reads=%0d quant_reads=%0d output_words=%0d request_stalls=%0d tile_waits=%0d",
          sample, weight_reads, act_reads, quant_reads, output_words, request_stalls, tile_waits);
`endif
`ifndef NPU_GATE_SIM
      if (gather_words == 0 || gather_parallel == 0)
        $fatal(1, "CNN did not exercise parallel RF gathers");
      $display(
          "RF_GATHER_PROFILE sample=%0d words=%0d active_cycles=%0d parallel_cycles=%0d peak_lanes=%0d distinct_three_cycles=%0d conflict_cycles=%0d",
          sample, gather_words, gather_cycles, gather_parallel, gather_peak, gather_distinct_three,
          gather_conflicts);
      $display("FIFO_PROFILE sample=%0d cnn_pending_peak=%0d packed_word_peak=%0d", sample,
               queue_peak, pack_peak);
`endif
      $display(
          "SINGLE_INPUT sample=%0d ingress_cycles=%0d input_to_classification_cycles=%0d input_to_classification_us_at_50mhz=%0.2f PASS",
          sample, ingress_cycles, total_cycles, real'(total_cycles) / 50.0);
`ifndef NPU_GATE_SIM
      $display(
          "SINGLE sample=%0d useful_macs=%0d kernel_cycles=%0d elapsed_cycles=%0d kernel_utilization_pct=%0.2f system_utilization_pct=%0.2f latency_us_at_50mhz=%0.2f PASS",
          sample, macs, kernel, elapsed,
          100.0 * real'(macs) / (real'(dut.i_core.i_stream.i_engine.MACS) * real'(kernel)),
          100.0 * real'(macs) / (real'(dut.i_core.i_stream.i_engine.MACS) * real'(elapsed)),
          real'(elapsed) / 50.0);
`endif
    end
    $display("SINGLE PASS samples=%0d checks=%0d", samples, checks);
    $finish;
  end
  initial begin
    #2000000000;
    $fatal(1, "Global timeout");
  end
endmodule
