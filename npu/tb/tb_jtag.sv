`timescale 1ns / 1ps
module tb_jtag;
  logic clk = 0, rst_n = 0, tck = 0, tms = 1, tdi = 0;
  always #10 clk = ~clk;
  wire tdo, halted, done, pass;
  logic hreq = 0, hwe = 0;
  logic [31:0] ha = 0, hd = 0;
  wire hg, hv, he;
  wire [31:0] hr;
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b1),
    .tck_i             (tck),
    .tms_i             (tms),
    .td_i              (tdi),
    .td_o              (tdo),
    .cpu_debug_halted_o(halted),
    .host_req_i        (hreq),
    .host_we_i         (hwe),
    .host_be_i         (4'hf),
    .host_addr_i       (ha),
    .host_wdata_i      (hd),
    .host_gnt_o        (hg),
    .host_rvalid_o     (hv),
    .host_error_o      (he),
    .host_rdata_o      (hr),












    .irq_o          (),
    .cpu_test_done_o(done),
    .cpu_test_pass_o(pass)
  );
  `include "db_jtag_tasks.svh"
  int removed_page_errors = 0;
`ifndef NPU_GATE_SIM
  always @(posedge clk) begin
    if (dut.i_core.rvalid[3] && dut.i_core.bus_error[3] &&
        dut.i_core.mmio_addr[11:8] >= 3 && dut.i_core.mmio_addr[11:8] <= 5)
      removed_page_errors++;
  end
`endif
  int checks = 0, native_count = 0;
  bit stop_host = 0;
  task automatic eq(input logic [31:0] got, want, input string label);
    if (got !== want) $fatal(1, "%s got=%h want=%h", label, got, want);
    checks++;
  endtask
  task automatic halt_cpu;
    logic [31:0] s;
    dmi_write('h10, 32'h80000001);
    for (int j = 0; j < 40; j++) begin
      dmi_read('h11, s);
      if (s[9]) begin
        checks++;
        return;
      end
    end
    $fatal(1, "halt timeout status=%h halted=%b", s, halted);
  endtask
  task automatic resume_cpu;
    logic [31:0] s;
    dmi_write('h10, 32'h40000001);
    for (int j = 0; j < 40; j++) begin
      dmi_read('h11, s);
      if (s[17]) begin
        dmi_write('h10, 1);
        checks++;
        return;
      end
    end
    $fatal(1, "resume timeout %h", s);
  endtask
  task automatic abstract_wait;
    logic [31:0] s;
    for (int j = 0; j < 40; j++) begin
      dmi_read('h16, s);
      if (!s[12]) begin
        if (s[10:8]) $fatal(1, "abstract error %h", s);
        return;
      end
    end
    $fatal(1, "abstract busy");
  endtask
  task automatic reg_read(input logic [15:0] regno, output logic [31:0] v);
    dmi_write('h17, 32'h00220000 | regno);
    abstract_wait();
    dmi_read('h04, v);
  endtask
  task automatic reg_write(input logic [15:0] regno, input logic [31:0] v);
    dmi_write('h04, v);
    dmi_write('h17, 32'h00230000 | regno);
    abstract_wait();
  endtask
  task automatic host_write(input logic [31:0] a, v);
    int waited;
    @(negedge clk);
    hreq = 1;
    hwe = 1;
    ha = a;
    hd = v;
    waited = 0;
    do begin
      @(posedge clk);
      waited++;
      if (waited > 16) $fatal(1, "native host starved");
    end while (!hg);
    @(negedge clk);
    hreq = 0;
    if (!hv) @(negedge clk);
    if (!hv || he) $fatal(1, "host response");
  endtask
`ifdef NPU_GATE_SIM
  // SBA has no architectural bus-error input in this DM. Its unused internal
  // error net may be optimized. Exercise the shared XBAR error through host IO.
  task automatic host_bad_page(input logic [31:0] a);
    int waited;
    @(negedge clk);
    hreq = 1;
    hwe = 1;
    ha = a;
    hd = 1;
    waited = 0;
    do begin
      @(posedge clk);
      waited++;
      if (waited > 16) $fatal(1, "host error probe starved");
    end while (!hg);
    @(negedge clk);
    hreq = 0;
    if (!hv) @(negedge clk);
    if (!hv || !he) $fatal(1, "removed page did not return external error %h", a);
    removed_page_errors++;
  endtask
`endif
  logic [40:0] scan;
  logic [31:0] v, pc, ds;
  bit discard;
  logic [7:0] image[0:16383], gold[0:9];
  initial begin
    #100;
    rst_n = 1;
    repeat (8) tick(1, 0, discard);
    tick(0, 0, discard);
    select_ir(1);
    scan_dr(32, 0, scan);
    eq(scan[31:0], 1, "IDCODE");
    select_ir('h10);
    scan_dr(32, 0, scan);
    if (scan[3:0] != 1 || scan[9:4] != 7) $fatal(1, "DTMCS %h", scan);
    checks++;
    select_ir('h11);
    dmi_write('h10, 1);
    halt_cpu();
    reg_write('h1005, 32'h12345678);
    reg_read('h1005, v);
    eq(v, 32'h12345678, "x5");
    reg_write('h100a, 32'h89abcdef);
    reg_read('h100a, v);
    eq(v, 32'h89abcdef, "x10 scratch");
    // Preserve bootstrap registers before resuming its WFI.
    reg_write('h1005, 32'h40000000);
    reg_write('h1006, 0);
    resume_cpu();
    sba_write(32'h80000000, 32'h01234567);
    sba_read(32'h80000000, v);
    eq(v, 32'h01234567, "bank0");
    sba_write(32'h80001ffc, 32'h89abcdef);
    sba_read(32'h80001ffc, v);
    eq(v, 32'h89abcdef, "bank0 end");
    sba_write(32'h80002000, 32'h87654321);
    sba_read(32'h80002000, v);
    eq(v, 32'h87654321, "bank1");
    sba_write(32'h80003ffc, 32'hfedcba98);
    sba_read(32'h80003ffc, v);
    eq(v, 32'hfedcba98, "bank1 end");
    fork
      begin
        while (!stop_host) begin
          host_write(32'h80002100, 32'hbad00000 + native_count);
          native_count++;
        end
      end
      begin
        for (int j = 0; j < 8; j++) begin
          sba_write(32'h80002000, j);
          sba_read(32'h80002000, v);
          eq(v, j, "concurrent SBA");
        end
        stop_host = 1;
      end
    join
    sba_read(32'h80002100, v);
    eq(v, 32'hbad00000 + native_count - 1, "native/SBA SRAM visibility");
    if (native_count < 100) $fatal(1, "insufficient host contention");
    checks++;
    // SBA autoincrement crosses the physical bank boundary transparently.
    dmi_write('h38, 32'h00050000);
    dmi_write('h39, 32'h80001ffc);
    dmi_write('h3c, 32'h11112222);
    wait_sba();
    dmi_write('h3c, 32'h33334444);
    wait_sba();
    sba_read(32'h80001ffc, v);
    eq(v, 32'h11112222, "SBA auto bank0");
    sba_read(32'h80002000, v);
    eq(v, 32'h33334444, "SBA auto bank1");
    // CPU_CONTROL=0 resets only the hart; DM can halt it at the bootstrap again.
    sba_write(32'h40000008, 0);
    halt_cpu();
    resume_cpu();
    // DM survives system reset; SRAM contents survive too.
    dmi_write('h10, 3);
    dmi_read('h10, v);
    if (!v[1]) $fatal(1, "ndmreset");
    checks++;
    dmi_write('h10, 1);
    idle_ticks(16);
    sba_read(32'h80003ffc, v);
    eq(v, 32'hfedcba98, "SRAM preserved reset");
    // This DM version has no SBA bus-error input. Observe XBAR's real error
    // response; do not claim that DMI SBCS reports an unsupported error input.
    for (int page = 3; page <= 5; page++) begin
      sba_write(32'h40000000 + (page << 8), 1);
    end
`ifdef NPU_GATE_SIM
    for (int page = 3; page <= 5; page++) host_bad_page(32'h40000000 + (page << 8));
    eq(removed_page_errors, 3, "removed DMA pages return host errors");
`else
    eq(removed_page_errors, 3, "removed DMA pages rejected by XBAR");
`endif
    // Tiny CPU loop: addi x7,x7,1; jal x0,-4. Inspect and single-step it.
    sba_write(32'h80000080, 32'h00138393);
    sba_write(32'h80000084, 32'hffdff06f);
    sba_write(32'h4000000c, 32'h80000080);
    sba_write(32'h40000008, 1);
    halt_cpu();
    reg_read('h7b1, pc);
    reg_read('h1007, v);
    reg_write('h1007, 123);
    reg_read('h1007, v);
    eq(v, 123, "halted x7");
    reg_read('h7b0, ds);
    reg_write('h7b0, ds | 4);
    resume_cpu();
    for (int j = 0; j < 40; j++) begin
      dmi_read('h11, v);
      if (v[9]) break;
      if (j == 39) $fatal(1, "step timeout");
    end
    reg_read('h7b1, v);
    eq(v, pc == 32'h80000080 ? 32'h80000084 : 32'h80000080, "single step DPC");
    reg_write('h7b0, ds & ~32'd4);
    resume_cpu();
    // Real image programmed entirely through JTAG SBA, then run one MNIST frame.
    dmi_write('h10, 3);
    dmi_write('h10, 1);
    idle_ticks(16);
    $readmemh("sram0.hex", image);
    $readmemh("gold0_5.hex", gold, 0, 9);
    for (int j = 0; j < 16384; j += 4)
    sba_write(32'h80000000 + j, {image[j+3], image[j+2], image[j+1], image[j]});
    sba_write(32'h40000008, 1);
    for (int j = 0; j < 100; j++) begin
      sba_read(32'h40000004, v);
      if (done) begin
        if (!pass) $fatal(1, "MNIST CPU failure");
        break;
      end
      if (j == 99) $fatal(1, "MNIST timeout");
    end
    for (int j = 0; j < 10; j++) begin
      sba_read(32'h80001400 + (j & ~3), v);
      eq((v >> ((j % 4) * 8)) & 255, gold[j], "MNIST logits");
    end
    $display("JTAG PASS checks=%0d", checks);
    $finish;
  end
  initial begin
    #2000000000;
    $fatal(1, "JTAG global timeout");
  end
endmodule
