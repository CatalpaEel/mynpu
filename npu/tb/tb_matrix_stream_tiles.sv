`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_matrix_stream_tiles;
  logic clk = 0, rst_n = 0, hreq = 0, hwe = 0;
  always #10 clk = ~clk;
  logic [31:0] ha = 0, hd = 0;
  wire hg, hv, he;
  wire [31:0] hr;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b0),
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
    .cpu_test_done_o   (),
    .cpu_test_pass_o   ()
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
      if (cycles > 1000) $fatal(1, "host grant timeout %h", a);
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
  int full_steps = 0, macs = 0;
  always @(posedge clk)
    if(rst_n && dut.i_core.matrix_compute_valid && dut.i_core.matrix_compute_ready && dut.i_core.matrix_compute_multiply) begin
      macs += $countones(dut.i_core.matrix_row_mask) * $countones(dut.i_core.matrix_col_mask);
      if (dut.i_core.matrix_row_mask == 15 && dut.i_core.matrix_col_mask == 15) full_steps++;
    end
  function automatic int av(input int r, k, wide);
    return ((r + 1) * (k + 1) - 13) * (wide ? 257 : 1);
  endfunction
  function automatic int bv(input int k, c, wide);
    return ((k + 2) * (c - 2) + 7) * (wide ? 509 : 1);
  endfunction
  task automatic wait_unit(input int page);
    logic [31:0] s;
    for (int i = 0; i < 50000; i++) begin
      rd('h40000004 + 32'(page), s);
      if (s[2]) $fatal(1, "stream tile engine error page=%h", page);
      if (s[1] && !s[0]) return;
    end
    $fatal(1, "stream tile engine timeout");
  endtask
  task automatic run_case(input int id);
    int m, n, k, stream_inputs, before_macs, before_full, expected, output_index;
    bit out_fifo;
    logic [31:0] a, b, d, got;
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    m = id[1] ? 7 : 5;
    n = 6;
    k = id >= 4 ? 17 : 3;
    stream_inputs = id % 3 + 1;
    out_fifo = id[0];
    a = stream_inputs[0] ? 'h80006000 : 'h80001000;
    b = stream_inputs[1] ? 'h80006100 : 'h80002000;
    d = out_fifo ? 'h80006200 : 'h80003000;
    for (int r = 0; r < m; r++)
      for (int z = 0; z < k; z++)
        if (!stream_inputs[0]) wr(a + 32'((r * k + z) * 4), 32'(av(r, z, id % 2)));
    for (int z = 0; z < k; z++)
      for (int c = 0; c < n; c++)
        if (!stream_inputs[1]) wr(b + 32'((z * n + c) * 4), 32'(bv(z, c, id % 2)));
    if (out_fifo) begin
      wr('h40000208, d);
      wr('h40000218, 0);
      wr('h4000020c, 'h80003800);
      wr('h40000210, 32'(m * n));
      wr('h40000214, 2);
      wr('h40000200, 1);
    end
    wr('h40000108, a);
    wr('h4000010c, b);
    wr('h40000110, d);
    wr('h40000114, 32'(m));
    wr('h40000118, 32'(n));
    wr('h4000011c, 32'(k));
    wr('h40000130, 0);
    wr('h4000013c, 32'(id % 2));
    wr('h40000140, 4);
    wr('h40000134, 0);
    wr('h40000138, 0);
    before_macs = macs;
    before_full = full_steps;
    wr('h40000100, 1);
    // Send exactly the token contract: tile, K, A rows, B columns.
    for (int tr = 0; tr < m; tr += 4)
      for (int tc = 0; tc < n; tc += 4)
        for (int z = 0; z < k; z++) begin
          if (stream_inputs[0])
            for (int r = tr; r < m && r < tr + 4; r++) wr(a, 32'(av(r, z, id % 2)));
          if (stream_inputs[1])
            for (int c = tc; c < n && c < tc + 4; c++) wr(b, 32'(bv(z, c, id % 2)));
        end
    wait_unit('h100);
    if (out_fifo) wait_unit('h200);
    output_index = 0;
    for (int tr = 0; tr < m; tr += 4)
      for (int tc = 0; tc < n; tc += 4)
        for (int r = tr; r < m && r < tr + 4; r++)
          for (int c = tc; c < n && c < tc + 4; c++) begin
            expected = 0;
            for (int z = 0; z < k; z++) begin
              int x, y;
              x = id % 2 ? int'(16'(av(r, z, id % 2))) : int'($signed(8'(av(r, z, id % 2))));
              y = id % 2 ? int'($signed(16'(bv(z, c, id % 2)))) :
                  int'($signed(8'(bv(z, c, id % 2))));
              if (id % 2) x = int'($signed(16'(av(r, z, id % 2))));
              expected += x * y;
            end
            rd(out_fifo ? 'h80003800 + 32'(output_index * 4) : d + 32'((r * n + c) * 4), got);
            if (got !== 32'(expected))
              $fatal(
                  1, "stream tile case=%0d r/c=%0d/%0d got=%h expected=%h", id, r, c, got, expected
              );
            output_index++;
            checks++;
          end
    if (macs - before_macs != m * n * k || full_steps - before_full < k)
      $fatal(1, "stream matrix not full outer product");
    $display(
        "MATRIX STREAM TILE CASE id=%0d inputs=%0d fifo_out=%0d M/N/K=%0d/%0d/%0d full_steps=%0d PASS",
        id, stream_inputs, out_fifo, m, n, k, full_steps - before_full);
  endtask
  initial begin
    for (int id = 0; id < 8; id++) run_case(id);
    $display(
        "MATRIX STREAM TILES PASS cases=8 checks=%0d full_steps=%0d mixed-SRAM/FIFO/tails/INT8/INT16/backpressure/tile-order",
        checks, full_steps);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "matrix stream tiles timeout");
  end
endmodule
