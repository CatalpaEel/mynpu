`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_workloads;
  logic clk = 0, rst_n = 0, hreq = 0, hwe = 0;
  wire cpu_done, cpu_pass;
  always #10 clk = ~clk;
  logic [31:0] ha = 0, hd = 0;
  wire hg, hv, he;
  wire [31:0] hr;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b1),
    .tck_i             (1'b0),
    .tms_i             (1'b1),
    .td_i              (1'b0),
    .td_o              (),
    .cpu_debug_halted_o(),
    .host_req_i        (hreq),
    .host_we_i         (hwe),
    .host_be_i         (4'hf),
    .host_addr_i       (ha),
    .host_wdata_i      (hd),
    .host_gnt_o        (hg),
    .host_rvalid_o     (hv),
    .host_error_o      (he),
    .host_rdata_o      (hr),
    .irq_o             (),
    .cpu_test_done_o   (cpu_done),
    .cpu_test_pass_o   (cpu_pass)
  );
  int checks = 0;
  localparam logic [31:0] INPUT_A=32'h80001400, OUTPUT_D=32'h80001700,
    WEIGHTS=32'h80002000, MATRIX_B=32'h80002020, CHANNEL=32'h80006000;
  task automatic bus(input bit we, input logic [31:0] a, d, output logic [31:0] result);
    int cycles;
    @(negedge clk);
    hreq = 1;
    hwe = we;
    ha = a;
    hd = d;
    cycles = 0;
    do begin
      @(posedge clk);
      cycles++;
      if (cycles > 100) $fatal(1, "host grant timeout %h", a);
    end while (!hg);
    @(negedge clk);
    hreq = 0;
    if (!hv) @(negedge clk);
    if (!hv || he) $fatal(1, "host response/error %h", a);
    result = hr;
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    bus(1, a, d, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    bus(0, a, 0, d);
  endtask
  localparam logic [31:0] BASE = 32'h40000000;
  int control[3] = '{'h100, 'h200, 'h600};
  int queues[3] = '{'h124, 'h224, 'h658};
  int submitted[3] = '{'h12c, 'h22c, 'h660};
  int completed[3] = '{'h128, 'h228, 'h65c};
  int cycles = 0;
  int overlap_cycles = 0;
  int matrix_cycles = 0, vector_cycles = 0, cnn_cycles = 0;
  int completion_wait_cycles = 0, queue_wait_cycles = 0;
  int config_writes = 0, data_writes = 0;
  int last_matrix = 0, last_vector = 0, last_cnn = 0, last_overlap = 0;
  int last_completion_wait = 0, last_queue_wait = 0, last_config = 0, last_data = 0;
  bit cpu_profile_enable = 0;
  int cpu_bins[13] = '{default: 0};
  int cpu_instructions = 0, cpu_fetch_grant_wait = 0, cpu_data_grant_wait = 0;
  logic [31:0] last_cpu_address = 0;
  always @(posedge clk) begin
    if (dut.i_core.req[0] && dut.i_core.gnt[0]) last_cpu_address = dut.i_core.addr[0];
    if (cpu_profile_enable && !cpu_done) begin
      int reason;
      logic [31:0] address;
      address = dut.i_core.req[0] ? dut.i_core.addr[0] : last_cpu_address;
      reason = 12;
      if (!dut.i_core.cpu_rst_n) reason = 1;
      else if (dut.i_core.i_cpu.core_i.core_sleep_o) reason = 2;
      else if (!dut.i_core.i_cpu.core_i.lsu_ready_ex || !dut.i_core.i_cpu.core_i.lsu_ready_wb) begin
        if (address[31:14] == 18'h20000) reason = 3;
        else if (address[31:12] == 20'h40000) reason = 4;
        else if (npu_addr_pkg::is_rf_address(address)) reason = 5;
        else if (npu_addr_pkg::is_stream_address(address)) reason = 6;
        else reason = 7;
      end else if (dut.i_core.i_cpu.core_i.perf_imiss) reason = 8;
      else if (dut.i_core.i_cpu.core_i.id_stage_i.load_stall) reason = 9;
      else if (dut.i_core.i_cpu.core_i.id_stage_i.jr_stall) reason = 10;
      else if (!dut.i_core.i_cpu.core_i.id_ready) reason = 11;
      cpu_bins[0]++;
      cpu_bins[reason]++;
      if (!dut.i_core.i_cpu.core_i.core_sleep_o && dut.i_core.i_cpu.core_i.id_stage_i.minstret)
        cpu_instructions++;
      if (dut.i_core.req[4] && !dut.i_core.gnt[4]) cpu_fetch_grant_wait++;
      if (dut.i_core.req[0] && !dut.i_core.gnt[0]) cpu_data_grant_wait++;
    end
  end
  task automatic profile(input int id);
    $display(
        "WORKLOAD_PROFILE case=%0d matrix_busy=%0d vector_busy=%0d cnn_busy=%0d overlap=%0d completion_wait=%0d queue_wait=%0d config_writes=%0d data_writes=%0d",
        id, matrix_cycles - last_matrix, vector_cycles - last_vector, cnn_cycles - last_cnn,
        overlap_cycles - last_overlap, completion_wait_cycles - last_completion_wait,
        queue_wait_cycles - last_queue_wait, config_writes - last_config, data_writes - last_data);
    last_matrix = matrix_cycles;
    last_vector = vector_cycles;
    last_cnn = cnn_cycles;
    last_overlap = overlap_cycles;
    last_completion_wait = completion_wait_cycles;
    last_queue_wait = queue_wait_cycles;
    last_config = config_writes;
    last_data = data_writes;
  endtask
  always @(posedge clk) begin
    cycles++;
    if (dut.i_core.mat_busy) matrix_cycles++;
    if (dut.i_core.vec_busy) vector_cycles++;
    if (dut.i_core.cnn_busy) cnn_cycles++;
    if ((dut.i_core.mat_busy && dut.i_core.vec_busy) ||
        (dut.i_core.cnn_busy && dut.i_core.vec_busy) ||
        (dut.i_core.cnn_busy && dut.i_core.mat_busy))
      overlap_cycles++;
    if (cycles > 2000000) $fatal(1, "global workload timeout");
  end
  task automatic wait_register(input int unit_id, target, input bit space);
    logic [31:0] status, value;
    int start_cycle;
    start_cycle = cycles;
    for (int t = 0; t < 100000; t++) begin
      rd(BASE + control[unit_id] + 4, status);
      if (status[2]) $fatal(1, "engine fault unit=%0d", unit_id);
      rd(BASE + (space ? queues[unit_id] : completed[unit_id]), value);
      if (space ? value[15:0] < value[31:16] : (value - 32'(target) < 32'h80000000)) begin
        if (space) queue_wait_cycles += cycles - start_cycle;
        else completion_wait_cycles += cycles - start_cycle;
        return;
      end
    end
    $fatal(1, "workload wait timeout unit=%0d target=%0d", unit_id, target);
  endtask
  initial begin
    int fd, parsed, commands, previous_cycle, previous_checks, case_id;
    logic [31:0] op, a, b, got;
    string path;
    commands = 0;
    previous_cycle = 0;
    previous_checks = 0;
    case_id = -1;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);
    if ($value$plusargs("workload_cpu=%s", path)) begin
      fd = $fopen(path, "r");
      if (!fd) $fatal(1, "cannot open CPU image");
      commands = 0;
      while (!$feof(
          fd
      )) begin
        parsed = $fscanf(fd, "%h\n", got);
        if (parsed != 1) $fatal(1, "malformed CPU image");
        wr(32'h80000000 + commands * 4, got);
        commands++;
      end
      $fclose(fd);
      wr(BASE + 12, 32'h80000080);
      previous_cycle = cycles;
      cpu_profile_enable = 1;
      wr(BASE + 8, 1);
      while (!cpu_done) @(negedge clk);
      cpu_profile_enable = 0;
      if (!cpu_pass) $fatal(1, "CPU workload failed");
      $display(
          "GENERAL_CPU_PROFILE cycles=%0d reset_boot=%0d wfi=%0d lsu_sram=%0d lsu_mmio=%0d lsu_rf=%0d lsu_fifo=%0d lsu_other=%0d fetch=%0d load_hazard=%0d jump_hazard=%0d pipeline=%0d other_awake=%0d instructions=%0d fetch_grant_wait=%0d data_grant_wait=%0d",
          cpu_bins[0], cpu_bins[1], cpu_bins[2], cpu_bins[3], cpu_bins[4], cpu_bins[5],
          cpu_bins[6], cpu_bins[7], cpu_bins[8], cpu_bins[9], cpu_bins[10], cpu_bins[11],
          cpu_bins[12], cpu_instructions, cpu_fetch_grant_wait, cpu_data_grant_wait);
      $display("GENERAL CPU PASS words=%0d cycles=%0d", commands - 32, cycles - previous_cycle);
      $finish;
    end
    if (!$value$plusargs("workloads=%s", path)) $fatal(1, "missing workload file");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open workload file");
    while (!$feof(
        fd
    )) begin
      parsed = $fscanf(fd, "%h %h %h\n", op, a, b);
      if (parsed != 3) $fatal(1, "malformed workload command %0d", commands);
      commands++;
      case (op)
        0: begin
          wr(a, b);
          if (a[31:12] == BASE[31:12]) config_writes++;
          else data_writes++;
        end
        1: begin
          if (a >= 3) $fatal(1, "invalid space unit");
          wait_register(int'(a), 0, 1);
        end
        2: begin
          if (a >= 3) $fatal(1, "invalid wait unit");
          wait_register(int'(a), int'(b), 0);
        end
        3: begin
          rd(a, got);
          if (got !== b)
            $fatal(
                1,
                "workload mismatch command=%0d case=%0d address=%h got=%h expected=%h",
                commands,
                case_id,
                a,
                got,
                b
            );
          checks++;
        end
        4: begin
          if (case_id >= 0)
            $display(
                "WORKLOAD case=%0d cycles=%0d checks=%0d",
                case_id,
                cycles - previous_cycle,
                checks - previous_checks
            );
          if (case_id >= 0) profile(case_id);
          case_id = int'(a);
          previous_cycle = cycles;
          previous_checks = checks;
        end
        default: $fatal(1, "invalid workload opcode");
      endcase
    end
    $fclose(fd);
    $display("WORKLOAD case=%0d cycles=%0d checks=%0d", case_id, cycles - previous_cycle,
             checks - previous_checks);
    profile(case_id);
    $display("GENERAL WORKLOADS PASS checks=%0d commands=%0d cycles=%0d overlap_cycles=%0d",
             checks, commands, cycles, overlap_cycles);
    $finish;
  end
endmodule
