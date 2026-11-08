`timescale 1ns / 1ps
// Port-only checks run unchanged on RTL and the mapped netlist.
module tb_netlist_units;
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
  localparam logic [31:0] M='h40000000, S0='h80006000, S1='h80006100, S2='h80006200, S3='h80006300;
  task automatic restart;
    @(negedge clk);
    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (8) @(negedge clk);
  endtask
  task automatic expect_word(input logic [31:0] a, v);
    logic [31:0] got;
    rd(a, got);
    if (got !== v) $fatal(1, "unit-smoke addr=%h got=%h expected=%h", a, got, v);
    checks++;
  endtask

  task automatic wait_unit(input int page);
    logic [31:0] s;
    for (int n = 0; n < 3000; n++) begin
      rd(M + 32'(page) + 4, s);
      if (s[2]) $fatal(1, "unit fault %h", page);
      if (s[1] && !s[0]) return;
    end
    $fatal(1, "unit timeout %h", page);
  endtask
  task automatic quant(input int source);
    int base;
    base = 'h700 + source * 64;
    wr(M + 32'(base + 4), 1);
    wr(M + 32'(base + 12), 0);
    wr(M + 32'(base + 24), 255);
    wr(M + 32'(base + 32), 'h80001801);
    wr(M + 32'(base), 3);
  endtask
  initial begin
    logic [31:0] x[4];
    longint unsigned product;
    longint signed signed_product;
    x = '{32'hf8a432eb, 32'd7, 32'h7fffffff, 32'h80000000};
    restart();
    expect_word(M + 'h084, 'h0002007f);
    for (int op_id = 0; op_id < 3; op_id++) begin
      int opcode;
      opcode = op_id == 0 ? 24 : op_id == 1 ? 19 : 20;
      wr(M + 'h200, 2);
      for (int n = 0; n < 4; n++) wr('h80001400 + 32'(4 * n), x[n]);
      wr(M + 'h208, 'h80001400);
      wr(M + 'h20c, 'h80001800);
      wr(M + 'h210, 4);
      wr(M + 'h214, 32'(128 | opcode));
      wr(M + 'h230, 13);
      wr(M + 'h200, 1);
      wait_unit('h200);
      for (int n = 0; n < 4; n++) begin
        product = 64'(x[n]) * 64'd13;
        signed_product = longint'($signed(x[n])) * 64'sd13;
        expect_word(
            'h80001800 + 32'(4 * n),
            op_id == 0 ? product[31:0] : op_id == 1 ? product[63:32] : 32'(signed_product >>> 32));
      end
    end
    wr(M + 'h200, 2);
    wr('h80001400, 'h01020304);
    wr('h80001404, 'h05060708);
    wr('h80001804, 'hdeadbeef);
    wr(M + 'h210, 7);
    wr(M + 'h214, 'hd8);
    wr(M + 'h230, 3);
    wr(M + 'h200, 1);
    wait_unit('h200);
    expect_word('h80001800, 'h0306090c);
    expect_word('h80001804, 'hde121518);

    restart();
    quant(1);
    wr('h80001800, 'hdeadbeef);
    wr('h80001804, 'hdeadbeef);
    wr('h80001400, 6);
    for (int n = 0; n < 5; n++) wr('h80002000 + 32'(4 * n), 32'(n + 2));
    wr(M + 'h108, 'h80001400);
    wr(M + 'h10c, 'h80002000);
    wr(M + 'h110, 'h80001900);
    wr(M + 'h114, 1);
    wr(M + 'h118, 5);
    wr(M + 'h11c, 1);
    wr(M + 'h100, 1);
    wait_unit('h100);
    expect_word('h80001800, 'h18120cef);
    expect_word('h80001804, 'hdead241e);
    expect_word(M + 'h764, 5);
    expect_word(M + 'h768, 5);
    expect_word(M + 'h76c, 5);

    restart();
    quant(0);
    wr('h80001800, 'hdeadbeef);
    wr('h80001804, 'hdeadbeef);
    wr('h80001400, 'h09080706);
    wr('h80001404, 10);
    wr('h80002000, 0);
    wr('h80002004, 2);
    wr('h80002008, 0);
    wr(M + 'h608, 'h80001400);
    wr(M + 'h60c, 'h80002000);
    wr(M + 'h610, 'h80001900);
    wr(M + 'h614, 5);
    wr(M + 'h618, 'h800040e0);
    wr(M + 'h61c, 1);
    wr(M + 'h620, 1);
    wr(M + 'h624, 5);
    // count5, middle row only, left/right pad, x=y=dst-index=0.
    wr(M + 'h628, 4 | (2 << 4) | (1 << 7) | (1 << 8));
    wr(M + 'h600, 1);
    wait_unit('h600);
    expect_word('h80001800, 'h100e0cef);
    expect_word('h80001804, 'hdead1412);
    expect_word(M + 'h724, 5);
    expect_word(M + 'h728, 5);
    expect_word(M + 'h72c, 5);
    $display(
        "UNIT SMOKE PASS checks=%0d INT32-multiply/high-signed/high-unsigned/SIMD8/tail/Matrix-pack/CNN-pack/real-ACK-counts",
        checks);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "unit smoke timeout");
  end
endmodule
