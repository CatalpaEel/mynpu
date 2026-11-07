`timescale 1ns / 1ps
// VPG2 32-bit instructions against an independent 64-bit oracle, memory stalls and
// stream backpressure. No CNN assumptions or internal pipeline probes.
module tb_vector_program;
  logic clk_i = 0, rst_ni = 0, start_i = 0;
  always #10 clk_i = ~clk_i;
  logic [31:0] a_i = 32'h80002000, b_i = 32'h80001000, d_i, scalar_i;
  logic [12:0] len_i;
  logic [7:0] op_i;
  logic [31:0] program_cfg_i = 32'h20b;
  logic [15:0][31:0] program_i;
  function automatic logic [31:0] ins(input int op, rd, ra, rb = 0, imm = 0,
                                      input bit immediate = 0);
    return 32'(op | (rd << 5) | (ra << 7) | (rb << 9) | (int'(immediate) << 11) | (imm << 12));
  endfunction
  wire busy_o, done_o, fault_o, req_o, we_o;
  wire [3:0] be_o;
  wire [31:0] addr_o, wdata_o;
  logic rvalid_i = 0, error_i = 0;
  logic [31:0] rdata_i = 0;
  int ticks = 0, sent = 0, checks = 0, jobs = 0, inject_kind = -1;
  wire gnt_i = req_o && ticks % 5 != 2 && ticks % 7 != 3;
  logic [7:0] memory[16384];
  logic signed [31:0] inputs[1024];
  wire stream_ready_o;
  wire stream_valid_i = op_i[6] && busy_o && sent < int'(len_i);
  wire [31:0] stream_data_i = inputs[sent < 1024 ? sent : 0];
  vector_task_fixture dut (.*);
  bit injected = 0;
  int input_reads = 0, parameter_reads = 0, byte_writes = 0;
  always @(posedge clk_i) begin
    ticks++;
    rvalid_i <= gnt_i;
    error_i <= 0;
    if (stream_valid_i && stream_ready_o) sent++;
    if (gnt_i) begin
      int kind;
      kind = we_o ? 3 : addr_o == b_i ? 0 : addr_o == b_i + 4 ? 1 : 2;
      if (!injected && kind == inject_kind) begin
        error_i <= 1;
        injected = 1;
      end
      if (!we_o) begin
        if (kind == 2) input_reads++;
        else parameter_reads++;
      end
      for (int b = 0; b < 4; b++) begin
        rdata_i[b*8+:8] <= memory[addr_o[13:0]+b];
        if (we_o && be_o[b]) begin
          memory[addr_o[13:0]+b] <= wdata_o[b*8+:8];
          byte_writes++;
        end
      end
      if (addr_o[1:0] != 0) $fatal(1, "Unaligned vector bus request");
    end
  end
  task automatic word(input int addr, input logic [31:0] data);
    for (int b = 0; b < 4; b++) memory[addr+b] = data[b*8+:8];
  endtask
  function automatic logic [7:0] reference(input logic signed [31:0] a, m, b, input int zero,
                                           input bit relu);
    longint signed value, magnitude, rounded, remainder;
    logic signed [31:0] q;
    value = longint'(a) * longint'(m) + longint'(b);
    magnitude = value < 0 ? -value : value;
    rounded = magnitude / 16777216;
    remainder = magnitude % 16777216;
    if (remainder > 8388608 || (remainder == 8388608 && rounded % 2 != 0)) rounded++;
    q = 32'(value < 0 ? -rounded : rounded);
    q = q + 32'(zero);
    if (relu && q < zero) q = zero;
    return q < 0 ? 0 : q > 255 ? 255 : 8'(q);
  endfunction
  task automatic run_job(input int len, offset, seed, input bit stream, activation,
                         input int error_kind = -1);
    logic signed [31:0] multiplier, bias;
    int limit;
    logic [7:0] expected;
    @(negedge clk_i);
    len_i = 13'(len);
    d_i = 32'h80000100 + 32'(offset);
    scalar_i = 32'(seed % 3 == 0 ? 0 : seed % 3 == 1 ? 128 : 255);
    op_i = 8'ha0 | (stream ? 8'h40 : 0);
    program_i = 0;
    program_i[0] = ins(27, 2, 1, 0, 4);
    program_i[1] = ins(27, 1, 1);
    program_i[2] = ins(24, 3, 0, 1);
    program_i[3] = ins(20, 0, 0, 1);
    program_i[4] = ins(16, 3, 3, 2);
    program_i[5] = ins(23, 0, 0, 2);
    program_i[6] = ins(22, 0, 3, 0) | (24 << 14);
    program_i[7] = ins(29, 3, 0);
    program_i[8] = ins(1, 0, 0, 3);
    program_i[9] = activation ? ins(5, 0, 0, 3) : ins(5, 0, 0, 0, 0, 1);
    program_i[10] = ins(4, 0, 0, 0, 255, 1);
    program_cfg_i = 32'h20b;
    multiplier=seed%5==0 ? 32'h00800000 : seed%5==1 ? 32'h80000000 : seed%5==2 ? 32'h7fffffff : seed%5==3 ? -16384 : 0;
    bias = seed % 3 == 0 ? 0 : seed % 3 == 1 ? -8388608 : 32'h7fffffff;
    word('h1000, multiplier);
    word('h1004, bias);
    for (int i = 0; i < len; i++) begin
      case (i % 10)
        0: inputs[i] = 1;
        1: inputs[i] = -1;
        2: inputs[i] = 3;
        3: inputs[i] = -3;
        4: inputs[i] = 32'h7fffffff;
        5: inputs[i] = 32'h80000000;
        default: inputs[i] = 32'((i * 7919 + seed * 37) ^ 32'hc013f147);
      endcase
      word('h2000 + i * 4, inputs[i]);
    end
    for (int i = 'hfc; i < 'h108 + len; i++) memory[i] = 8'ha5;
    sent = 0;
    input_reads = 0;
    parameter_reads = 0;
    byte_writes = 0;
    inject_kind = error_kind;
    injected = 0;
    start_i = 1;
    @(negedge clk_i);
    start_i = 0;
    limit = 0;
    while (busy_o && limit < 30000) begin
      @(negedge clk_i);
      limit++;
    end
    if (limit == 30000) $fatal(1, "Program timeout len=%0d stream=%0d", len, stream);
    if (error_kind >= 0) begin
      if (!injected || !fault_o || done_o) $fatal(1, "Missing program fault kind=%0d", error_kind);
      checks++;
    end else begin
      if(!done_o || fault_o || parameter_reads!=2 || input_reads!=(stream ? 0 : len) || byte_writes!=len)
        $fatal(1, "Program completion/accounting len=%0d stream=%0d", len, stream);
      for (int i = 'hfc; i < 'h108 + len; i++) begin
        expected = i >= 'h100 + offset && i < 'h100 + offset + len ?
            reference(inputs[i-'h100-offset], multiplier, bias, int'(scalar_i), activation) : 8'ha5;
        if (memory[i] !== expected)
          $fatal(
              1,
              "Program mismatch len=%0d seed=%0d byte=%0d got=%h expected=%h",
              len,
              seed,
              i,
              memory[i],
              expected
          );
        checks++;
      end
    end
    jobs++;
    @(negedge clk_i);
    if (done_o || fault_o || busy_o) $fatal(1, "Program status was not a pulse");
  endtask
  // Non-quantization programs: retain a saved input, wide multiply/add and
  // all 33 two-word rounded shift counts; also exercise a sequential bitwise chain.
  task automatic generic_job(input int shift_count, input bit light_chain, stream);
    longint signed value, magnitude, rounded, remainder, divisor;
    logic signed [31:0] expected;
    int limit;
    @(negedge clk_i);
    program_cfg_i = 4;
    program_i = 0;
    op_i = stream ? 8'h60 : 8'h20;
    len_i = 17;
    d_i = 32'h80000100;
    scalar_i = light_chain ? 3 : -3;
    sent = 0;
    inject_kind = -1;
    input_reads = 0;
    parameter_reads = 0;
    byte_writes = 0;
    if (light_chain) begin
      program_i[0] = ins(1, 0, 0, 3);
      program_i[1] = ins(8, 0, 0, 0, 119, 1);
      program_i[2] = ins(5, 0, 0, 0, -3, 1);
      program_i[3] = ins(4, 0, 0, 0, 300, 1);
    end else begin
      // Preserve x in r1; compute x*(-3)+x as a pair of 32-bit words.
      program_i[0] = ins(2, 1, 0);
      program_i[1] = ins(24, 2, 0, 0, -3, 1);
      program_i[2] = ins(20, 0, 0, 0, -3, 1);
      program_i[3] = ins(16, 2, 2, 1);
      program_i[4] = ins(23, 0, 0, 1);
      program_i[5] = ins(22, 0, 2, 0) | (shift_count << 14);
      program_cfg_i = 6;
    end
    for (int i = 0; i < 17; i++) begin
      inputs[i] = 32'((i * 7919) ^ 32'hc013f147);
      word('h2000 + i * 4, inputs[i]);
    end
    start_i = 1;
    @(negedge clk_i);
    start_i = 0;
    limit = 0;
    while (busy_o && limit < 1000) begin
      @(negedge clk_i);
      limit++;
    end
    if(!done_o || fault_o || limit==1000 || parameter_reads!=0 || input_reads!=(stream ? 0 : 17) || byte_writes!=68)
      $fatal(1, "Generic job completion failed");
    for (int i = 0; i < 17; i++) begin
      if (light_chain) begin
        expected = (inputs[i] + 32'd3) ^ 32'd119;
        if (expected < -3) expected = -3;
        if (expected > 300) expected = 300;
      end else begin
        value = -2 * longint'(inputs[i]);
        if (shift_count == 0) rounded = value;
        else begin
          magnitude = value < 0 ? -value : value;
          // Division reference is independent of hardware guard/sticky logic.
          divisor = 64'd1 << shift_count;
          if (shift_count == 63) begin
            rounded = 0;
          end else begin
            rounded = magnitude / divisor;
            remainder = magnitude % divisor;
            if (remainder > divisor / 2 || remainder == divisor / 2 && rounded % 2 != 0) rounded++;
          end
          if (value < 0) rounded = -rounded;
        end
        expected = 32'(rounded);
      end
      if({memory['h100+i*4+3],memory['h100+i*4+2],memory['h100+i*4+1],memory['h100+i*4]}!==expected)
        $fatal(
            1, "Generic program mismatch shift=%0d light=%0d i=%0d", shift_count, light_chain, i
        );
      checks++;
    end
    jobs++;
    @(negedge clk_i);
  endtask
  task automatic invalid_program(input int opcode, amount = 0);
    int limit;
    @(negedge clk_i);
    op_i = 'h20;
    len_i = 1;
    d_i = 'h80000100;
    scalar_i = 0;
    program_cfg_i = 1;
    program_i = 0;
    program_i[0] = ins(opcode, 0, 0, 0) | (amount << 14);
    input_reads = 0;
    parameter_reads = 0;
    byte_writes = 0;
    inject_kind = -1;
    injected = 0;
    word('h2000, 32'hffffffff);
    start_i = 1;
    @(negedge clk_i);
    start_i = 0;
    limit = 0;
    while (busy_o && limit < 100) begin
      @(negedge clk_i);
      limit++;
    end
    if (!fault_o || done_o || byte_writes != 0 || limit == 100)
      $fatal(1, "Unsupported VPG2 instruction did not fault op=%0d", opcode);
    checks++;
    jobs++;
    @(negedge clk_i);
    if (fault_o || busy_o) $fatal(1, "Invalid program fault did not settle");
  endtask
  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int stream = 0; stream < 1; stream++) begin
      for (int offset = 0; offset < 4; offset++)
      for (int n = 1; n <= 17; n++) run_job(n, offset, n + offset, 1'(stream), 1'(n % 2));
      run_job(196, 3, 7, 1'(stream), 1);
      run_job(1024, 1, 11, 1'(stream), 0);
      for (int kind = 0; kind < 4; kind++)
      if (!stream || kind != 2) begin
        run_job(17, 2, kind, 1'(stream), 1, kind);
        run_job(17, 2, kind, 1'(stream), 1);
      end
    end
    for (int shift_count = 0; shift_count <= 32; shift_count++) generic_job(shift_count, 0, 0);
    generic_job(0, 1, 0);
    invalid_program(25);
    invalid_program(28);
    invalid_program(22, 33);
    run_job(17, 0, 7, 0, 1);

    $display(
        "VECTOR PROGRAM PASS jobs=%0d checks=%0d memory source, signed INT32, ties, saturation, byte masks, faults/retry",
        jobs, checks);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "Vector program timeout");
  end
endmodule
