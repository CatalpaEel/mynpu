`timescale 1ns / 1ps
// Real CPU sleeps first. Real unit jobs then complete/fault, waking one source.
module tb_irq_wake;
  logic clk = 0, rst_n = 0, hreq = 0, hwe = 0;
  always #10 clk = ~clk;
  logic [31:0] ha = 0, hd = 0;
  wire hg, hv, he;
  wire [31:0] hr;
  wire [4:0] irq;
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
    .irq_o             (irq),
    .cpu_test_done_o   (),
    .cpu_test_pass_o   ()
  );
  int checks = 0, pc;
  localparam logic [31:0] RF_LAST = npu_addr_pkg::RF_BASE + npu_addr_pkg::RF_BYTES - 4;
  localparam logic [31:0] MAIL = 32'h80001000, A = 32'h80001400, B = 32'h80001404, D = 32'h80001500;
  task automatic bus(input bit we, input logic [31:0] address, value, output logic [31:0] result);
    int limit;
    @(negedge clk);
    hreq = 1;
    hwe = we;
    ha = address;
    hd = value;
    limit = 0;
    do begin
      @(posedge clk);
      limit++;
      if (limit > 100) $fatal(1, "host grant timeout");
    end while (!hg);
    @(negedge clk);
    hreq = 0;
    if (!hv) @(negedge clk);
    if (!hv || he) $fatal(1, "host response %h", address);
    result = hr;
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] r;
    bus(1, a, d, r);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    bus(0, a, 0, d);
  endtask
  function automatic logic [31:0] lui(input int r, u);
    return 32'(u << 12 | r << 7 | 'h37);
  endfunction
  function automatic logic [31:0] addi(input int d, s, v);
    return 32'((v & 4095) << 20 | s << 15 | d << 7 | 'h13);
  endfunction
  function automatic logic [31:0] sw(input int s, b, o);
    return 32'(((o >> 5) & 127) << 25 | s << 20 | b << 15 | 2 << 12 | (o & 31) << 7 | 'h23);
  endfunction
  function automatic logic [31:0] lw(input int d, b, o);
    return 32'((o & 4095) << 20 | b << 15 | 2 << 12 | d << 7 | 'h03);
  endfunction
  task automatic emit(input logic [31:0] word);
    wr(32'h80000000 + 32'(pc), word);
    pc += 4;
  endtask
  task automatic load_program(input int id, base);
    for (int n = 0; n < 64; n++) wr(32'h80000080 + 32'(n * 4), 32'h00000013);
    pc = 'h80;
    emit(lui(5, 1 << (id - 12)));
    emit(32'h30429073);  // csrw mie,x5
    emit(32'h30047073);  // mstatus.MIE=0: wake without taking a trap
    emit(lui(6, 'h80001));
    emit(addi(7, 0, 1));
    emit(sw(7, 6, 0));
    emit(32'h10500073);  // WFI
    emit(32'h34402473);
    emit(sw(8, 6, 4));  // csrr x8,mip
    emit(lui(9, 'h40000));
    emit(addi(9, 9, base));
    emit(lw(10, 9, 4));
    emit(sw(10, 6, 8));
    emit(addi(7, 0, 2));
    emit(sw(7, 6, 0));
    emit(32'h0000006f);
  endtask
  task automatic launch(input int unit_id, input bit fault_case);
    wr(A, 2);
    wr(B, unit_id == 0 && fault_case ? 32'h00000403 : 32'd3);
    if (unit_id == 0) begin
      wr('h40000108, A);
      wr('h4000010c, B);
      wr('h40000110, D);
      wr('h40000114, 1);
      wr('h40000118, fault_case ? 2 : 1);
      wr('h4000011c, 1);
      matrix_config(8);
      if (fault_case) begin
        wr('h40000744, 1);
        wr('h40000748, 0);
        wr('h4000074c, 0);
        wr('h40000750, 0);
        wr('h40000754, 'h80000000);
        wr('h40000758, 'h7fffffff);
        wr('h4000075c, 0);
        wr('h40000760, RF_LAST);
        wr('h40000740, 1);  // second result is outside the RF aperture
      end
      wr('h40000100, 1);
    end else if (unit_id == 1) begin
      wr('h40000208, A);
      wr('h40000218, B);
      wr('h4000020c, D);
      wr('h40000210, 1);
      if (fault_case) begin
        wr('h40000234, 1);
        wr('h40000240, 31);
      end  // runtime illegal VPG opcode
      wr('h40000214, fault_case ? 'h20 : 1);
      wr('h40000200, 1);
    end else begin
      wr('h80002000, 0);
      wr('h80002004, 3);
      wr('h80002008, 0);
      wr('h8000200c, 'h300);
      wr('h80002010, 0);
      if (fault_case) wr(RF_LAST, 2);
      wr('h40000608, fault_case ? RF_LAST : A);
      wr('h4000060c, 'h80002000);
      wr('h40000610, D);
      wr('h40000614, 1);
      wr('h40000618, 'h80004080);
      wr('h4000061c, fault_case ? 2 : 1);
      wr('h40000620, 1);
      wr('h40000624, fault_case ? 4 : 1);
      wr('h4000062c, 0);
      wr('h40000628, (1 << 0) | (2 << 4) | (1 << 7) | (1 << 8));
      wr('h40000600, 1);
    end
  endtask
  // Translate the regression oracle's old layout tuple into explicit MMIO fields.
  task automatic matrix_config(input logic [31:0] f);
    wr('h4000013c, {31'b0, f[4]});
    wr('h40000140, f[3] ? (f[4] ? 2 : 1) : 4);
    wr('h40000130, f <= 31 ? (f & 7) : f);
  endtask
  initial begin
    logic [31:0] v, pending, status, count;
    int base, id, limit;
    for (int u = 0; u < 3; u++)
    for (int f = 0; f < 2; f++) begin
      @(negedge clk);
      rst_n = 0;
      hreq = 0;
      repeat (8) @(negedge clk);
      rst_n = 1;
      repeat (8) @(negedge clk);
      base = u == 0 ? 'h100 : u == 1 ? 'h200 : 'h600;
      id = 16 + u;
      wr(MAIL, 0);
      wr(MAIL + 4, 0);
      wr(MAIL + 8, 0);
      rd('h40000070, v);
      if (v !== 'h70000) $fatal(1, "IRQ capability");
      load_program(id, base);
      wr('h40000008, 1);
      for (limit = 0; limit < 1000; limit++) begin
        rd(MAIL, v);
        if (v == 1) break;
      end
      if (v != 1) $fatal(1, "CPU ready timeout");
      for (limit = 0; limit < 1000 && !dut.i_core.i_cpu.core_sleep_o; limit++) @(negedge clk);
      if (!dut.i_core.i_cpu.core_sleep_o || irq != 0) $fatal(1, "CPU did not sleep before event");
      launch(u, 1'(f));
      for (limit = 0; limit < 2000; limit++) begin
        rd(MAIL, v);
        if (v == 2) break;
      end
      if (v != 2) $fatal(1, "WFI not woken unit=%0d fault=%0d", u, f);
      rd(MAIL + 4, pending);
      rd(MAIL + 8, status);
      rd(32'h40000000 + 32'(base) + (u == 2 ? 'h5c : 'h28), count);
      if((pending&32'h70000)!==32'(1<<id) || irq!==5'(1<<u) || status!==(f?32'd4:32'd2) || count!==(f?32'd0:32'd1))
        $fatal(
            1,
            "IRQ cause unit=%0d fault=%0d mip=%h status=%h count=%0d irq=%b",
            u,
            f,
            pending,
            status,
            count,
            irq
        );
      if (!f) begin
        rd(D, v);
        if (v !== (u == 1 ? 32'd5 : 32'd6)) $fatal(1, "result");
      end
      wr(32'h40000000 + 32'(base), 8);
      if (irq !== (f ? 5'(1 << u) : 5'b0)) $fatal(1, "done ACK changed error level");
      wr(32'h40000000 + 32'(base), 2);
      if (irq != 0) $fatal(1, "idle clear failed");
      checks++;
      $display("IRQ WAKE CASE unit=%0d irq=%0d fault=%0d PASS", u, id, f);
    end
    // A pending CNN fault must not wake a CPU enabling only Matrix IRQ16.
    @(negedge clk);
    rst_n = 0;
    hreq = 0;
    repeat (8) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
    wr(MAIL, 0);
    load_program(16, 'h100);
    wr('h40000008, 1);
    for (limit = 0; limit < 1000; limit++) begin
      rd(MAIL, v);
      if (v == 1) break;
    end
    for (limit = 0; limit < 1000 && !dut.i_core.i_cpu.core_sleep_o; limit++) @(negedge clk);
    if (!dut.i_core.i_cpu.core_sleep_o) $fatal(1, "mask test did not sleep");
    launch(2, 1);
    for (limit = 0; limit < 1000 && irq != 5'b00100; limit++) @(negedge clk);
    repeat (32) @(negedge clk);
    rd(MAIL, v);
    if (v != 1 || !dut.i_core.i_cpu.core_sleep_o || irq != 5'b00100)
      $fatal(1, "masked CNN woke Matrix waiter");
    launch(0, 0);
    for (limit = 0; limit < 2000; limit++) begin
      rd(MAIL, v);
      if (v == 2) break;
    end
    rd(MAIL + 4, pending);
    rd(MAIL + 8, status);
    if (v != 2 || (pending & 32'h70000) != 32'h50000 || status != 2 || irq != 5'b00101)
      $fatal(1, "two pending source identification");
    wr('h40000100, 8);
    if (irq != 5'b00100) $fatal(1, "Matrix ACK cleared CNN");
    wr('h40000600, 2);
    if (irq != 0) $fatal(1, "CNN clear");
    checks++;
    $display("IRQ MASK PASS unrelated-source-stays-asleep/two-pending-MIP/independent-ACK");
    $display(
        "IRQ WAKE PASS cases=%0d real-CPU-WFI/three-distinct-sources/completion/runtime-fault/MIP/tickets",
        checks);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1, "IRQ wake timeout");
  end
endmodule
