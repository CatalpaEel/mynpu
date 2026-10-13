`timescale 1ns/1ps

// Full-SoC ASIC SRAM regression.  The CPU image is loaded through the real
// JTAG/SBA path because the foundry SRAM macro has no $readmemh initialization.
// Compile this testbench with the private RA1SHD_2048x32M8.v model.
module tb_mynpu_soc_asic_stress #(
  parameter integer BOOT_ROUNDS = 3,
  parameter integer SBA_WORDS = 64,
  parameter integer HALT_ROUNDS = 3,
  parameter integer CONTENTION_ROUNDS = 128,
  parameter integer NPU_LANES = 4,
  parameter CPU_IMAGE = (NPU_LANES==1) ? "generated/8k/cpu.hex" : "generated/8k-p4/cpu.hex",
  parameter MODEL_HEX = (NPU_LANES==1) ? "cnn_npu_int8/generated/8k/npu_word.hex" : "cnn_npu_int8/generated/8k-p4/npu_word.hex"
);
  localparam integer CPU_WORDS = 2048;
  logic clk=0, rst_ni=0, boot_ready=0;
  logic tck=0, tms=1, tdi=0, tdo, npu_irq, debug_halted;
  logic [31:0] cpu_image [0:CPU_WORDS-1];
  logic [31:0] model_image [0:2047];
  logic [31:0] value, expected;
  integer irq_edges;

  always #5 clk=~clk;
  always @(posedge npu_irq) irq_edges++;

  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(8192), .NPU_LANES(NPU_LANES),
    .USE_ASIC_SRAM(1'b1), .CPU_INIT_FILE("")
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .boot_ready_i(boot_ready),
    .npu_irq_o(npu_irq), .cpu_debug_halted_o(debug_halted),
    .tck_i(tck), .tms_i(tms), .td_i(tdi), .td_o(tdo)
  );

  task automatic tick(input bit ms, input bit di, output bit sample);
    tck=0; tms=ms; tdi=di; #20; sample=tdo; tck=1; #20;
  endtask
  task automatic select_ir(input logic [4:0] ir);
    bit discard;
    tick(1,0,discard); tick(1,0,discard); tick(0,0,discard); tick(0,0,discard);
    for (integer j=0;j<5;j++) tick(j==4,ir[j],discard);
    tick(1,0,discard); tick(0,0,discard);
  endtask
  task automatic idle_ticks(input integer n);
    bit discard; repeat(n) tick(0,0,discard);
  endtask
  task automatic scan_dr(input integer n, input logic [40:0] tx,
                         output logic [40:0] rx);
    bit sample; tick(1,0,sample); tick(0,0,sample); tick(0,0,sample); rx=0;
    for (integer j=0;j<n;j++) begin
      tick(j==n-1,tx[j],sample); rx[j]=sample;
    end
    tick(1,0,sample); tick(0,0,sample);
  endtask
  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,data,2'b10},response); idle_ticks(64);
    scan_dr(41,41'd0,response);
    if (response[1:0] != 0)
      $fatal(1,"ASIC DMI write failed addr=%h status=%h",addr,response[1:0]);
  endtask
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,32'd0,2'b01},response); idle_ticks(64);
    scan_dr(41,41'd0,response);
    if (response[1:0] != 0)
      $fatal(1,"ASIC DMI read failed addr=%h status=%h",addr,response[1:0]);
    data=response[33:2];
  endtask
  task automatic wait_sba;
    logic [31:0] status;
    for (integer j=0;j<40;j++) begin
      dmi_read(7'h38,status);
      if (status[14:12] || status[22]) $fatal(1,"ASIC SBA error %h",status);
      if (!status[21]) return;
    end
    $fatal(1,"ASIC SBA timeout");
  endtask
  task automatic wait_sba_clear_ignoring_busyerror;
    logic [31:0] status;
    for (integer j=0;j<80;j++) begin
      dmi_read(7'h38,status);
      if (!status[21]) return;
    end
    $fatal(1,"ASIC SBA did not leave busy state");
  endtask
  task automatic sba_write(input logic [31:0] addr, input logic [31:0] data);
    dmi_write(7'h38,32'h00040000); dmi_write(7'h39,addr);
    dmi_write(7'h3c,data); wait_sba();
  endtask
  task automatic sba_read(input logic [31:0] addr, output logic [31:0] data);
    dmi_write(7'h38,32'h00140000); dmi_write(7'h39,addr);
    wait_sba(); dmi_read(7'h3c,data);
  endtask
  task automatic wait_mailbox(input logic [31:0] want);
    // Each inference uses the physical single-port vector schedule.
    // Each SBA poll is intentionally slow because it goes through the DMI
    // scan chain.
    for (integer j=0;j<6000;j++) begin
      sba_read(32'h80001fc0,value);
      if (value == 32'hdeadbeef)
        $fatal(1,"ASIC firmware failed code=%h",value);
      if (value == want) return;
    end
    $fatal(1,"ASIC mailbox timeout want=%h last=%h",want,value);
  endtask
  task automatic wait_npu_busy;
    for (integer j=0;j<300;j++) begin
      sba_read(32'h70000004,value);
      if (value[0]) return;
    end
    $fatal(1,"ASIC NPU BUSY timeout");
  endtask
  task automatic cpu_halt_resume;
    dmi_write(7'h10,32'h80000001);
    for (integer j=0;j<80;j++) begin
      dmi_read(7'h11,value);
      if (value[9]) begin
        if (!debug_halted) $fatal(1,"ASIC debug_halted output missing");
        sba_read(32'h70000004,value);
        dmi_write(7'h10,32'h40000001);
        return;
      end
    end
    $fatal(1,"ASIC CPU halt timeout");
  endtask
  task automatic dmi_init;
    bit discard;
    repeat(6) tick(1,0,discard); tick(0,0,discard); select_ir(5'h11);
    // dmactive is cleared by PoR/reset; SBA writes after a reset must
    // explicitly reactivate the Debug Module before reloading CPU SRAM.
    dmi_write(7'h10,32'd1);
  endtask
  task automatic dmi_busy_protocol;
    logic [31:0] status;
    // Hold the SBA request before launching a read, then issue another
    // address access while sbbusy is asserted. The DM must set sbbusyerror,
    // keep the original request alive, and recover after W1C clearing.
    force dut.dm_master_gnt = 1'b0;
    dmi_write(7'h38,32'h00140000); // sbreadonaddr + 32-bit access
    dmi_write(7'h39,32'h80000000); // launches a read that cannot be granted
    dmi_write(7'h39,32'h80000004); // illegal update while SBA is busy
    dmi_read(7'h38,status);
    if (!status[21] || !status[22])
      $fatal(1,"ASIC SBA busy protocol not detected status=%h",status);
    release dut.dm_master_gnt;
    wait_sba_clear_ignoring_busyerror();
    // SBCS busyerror is write-one-to-clear; preserve the 32-bit access mode.
    dmi_write(7'h38,32'h00540000);
    dmi_read(7'h38,status);
    if (status[21] || status[22])
      $fatal(1,"ASIC SBA busy protocol did not recover status=%h",status);
    $display("[SOC-ASIC-STRESS] SBA busy/error/recovery passed");
  endtask
  task automatic random_tck_reset;
    bit discard;
    fork
      begin
        for (integer j=0;j<24;j++)
          tick($urandom_range(0,1),$urandom_range(0,1),discard);
      end
      begin
        #($urandom_range(1,73)); rst_ni=1'b0;
        #($urandom_range(37,91)); rst_ni=1'b1;
      end
    join
    dmi_init();
    $display("[SOC-ASIC-STRESS] asynchronous reset during JTAG activity passed");
  endtask
  task automatic random_reset_during_busy;
    bit discard;
    fork
      begin
        for (integer j=0;j<40;j++)
          tick($urandom_range(0,1),$urandom_range(0,1),discard);
      end
      begin
        #($urandom_range(1,73)); rst_ni=1'b0;
        #($urandom_range(37,91)); rst_ni=1'b1;
      end
    join
    dmi_init();
    load_cpu_image();
    $display("[SOC-ASIC-STRESS] asynchronous reset during active NPU/JTAG passed");
  endtask
  task automatic reset_during_sba;
    logic [40:0] response;
    // Keep the SBA request pending, then reset while the DMI response path is
    // still being shifted. The scan result is intentionally discarded; the
    // post-reset DMI reinitialization is the check.
    dmi_write(7'h38,32'h00140000);
    force dut.dm_master_gnt = 1'b0;
    scan_dr(41,{7'h39,32'h80000000,2'b10},response);
    fork
      begin
        idle_ticks(64);
        scan_dr(41,41'd0,response);
      end
      begin
        #($urandom_range(1,73)); rst_ni=1'b0;
        #($urandom_range(37,91)); rst_ni=1'b1;
      end
    join
    release dut.dm_master_gnt;
    dmi_init();
    $display("[SOC-ASIC-STRESS] reset during SBA/DMI response passed");
  endtask
  task automatic crossbar_contention_probe;
    // CPU is polling the NPU and touching its own mailbox while these SBA
    // reads exercise the third crossbar master. Do not write live firmware
    // memory; the check is response integrity and absence of SBA errors.
    for (integer j=0;j<CONTENTION_ROUNDS;j++) begin
      case ($urandom_range(0,3))
        0: sba_read(32'h80001fc0 + (($urandom_range(0,3)) * 4),value);
        1: sba_read(32'h70000004,value);
        2: sba_read(32'h70000018,value);
        default: sba_read(32'h7000001c,value);
      endcase
    end
    $display("[SOC-ASIC-STRESS] CPU/Debug/NPU crossbar contention passed rounds=%0d",CONTENTION_ROUNDS);
  endtask
  task automatic busy_local_access_probe;
    logic [31:0] local_word, status;
    // The single-port contract rejects host data access while the engine owns
    // the macro. Reads return a deterministic marker and record REG_ERROR;
    // writes complete at AXI level but do not alter SRAM.
    sba_read(32'h70004000,local_word);
    if (local_word !== 32'hdead_b001)
      $fatal(1,"ASIC BUSY local read marker mismatch %h",local_word);
    sba_read(32'h7000001c,status);
    if (status !== 32'hdead_b001)
      $fatal(1,"ASIC BUSY local access was not recorded status=%h",status);
    $display("[SOC-ASIC-STRESS] BUSY local read rejected with deterministic error");
    sba_write(32'h70004000,32'hfeedbeef);
  endtask
  task automatic busy_local_write_check;
    logic [31:0] local_word;
    sba_read(32'h70004000,local_word);
    if (local_word !== model_image[0])
      $fatal(1,"[SOC-ASIC-STRESS] BUSY local write changed data to %h expected=%h",local_word,model_image[0]);
    else
      $display("[SOC-ASIC-STRESS] BUSY local write was ignored as documented");
  endtask
  task automatic load_cpu_image;
    for (integer k=0;k<CPU_WORDS;k++)
      sba_write(32'h80000000+k*4,cpu_image[k]);
  endtask

  initial begin
    bit discard;
    logic [40:0] scan_response;
    $readmemh(CPU_IMAGE,cpu_image);
    $readmemh(MODEL_HEX,model_image);
    repeat(10) @(posedge clk); rst_ni=1;
    repeat(10) @(posedge clk);
    repeat(6) tick(1,0,discard); tick(0,0,discard);
    select_ir(5'h01); scan_dr(32,0,scan_response);
    if (scan_response[31:0] !== 32'h00000001)
      $fatal(1,"ASIC JTAG IDCODE mismatch %h",scan_response);
    select_ir(5'h11);
    dmi_write(7'h10,32'd1);
    dmi_busy_protocol();
    random_tck_reset();
    reset_during_sba();
    sba_read(32'h80000000,value);
    // The macro starts unknown; loading every word through SBA is intentional.
    load_cpu_image();
    for (integer k=0;k<SBA_WORDS;k++) begin
      expected=32'ha5000000 ^ (k*32'h01020305);
      sba_write(32'h70004000+k*4,expected);
      sba_read(32'h70004000+k*4,value);
      if (value !== expected) $fatal(1,"ASIC SBA stress mismatch word=%0d",k);
    end
    // Invalid layer count must enter ERROR and recover without a power reset.
    sba_write(32'h70000014,32'hff); sba_write(32'h70000000,32'h1);
    for (integer k=0;k<30;k++) begin sba_read(32'h70000004,value); if (value[2]) break; end
    if (!value[2]) $fatal(1,"ASIC invalid layer count did not set ERROR");
    sba_write(32'h70000000,32'h4); sba_read(32'h70000004,value);
    if (value[2]) $fatal(1,"ASIC ERROR clear failed");
    boot_ready=1;
    for (integer round=0;round<BOOT_ROUNDS;round++) begin
      wait_mailbox(32'h12345678);
      wait_npu_busy();
      busy_local_access_probe();
      crossbar_contention_probe();
      for (integer k=0;k<HALT_ROUNDS;k++) cpu_halt_resume();
      wait_mailbox(32'hc0dec0de);
      busy_local_write_check();
      sba_read(32'h80001fc8,value); if (value !== 2) $fatal(1,"ASIC class=%h",value);
      sba_read(32'h80001ff8,value); if (value !== 4) $fatal(1,"ASIC IRQ count=%h",value);
      sba_read(32'h80001fcc,value); if (value == 0) $fatal(1,"ASIC cycle count is zero");
      $display("[SOC-ASIC-STRESS] boot=%0d class=2 irq_count=4 cycles=%0d",round,value);
      if (round+1<BOOT_ROUNDS) begin
        // Start the next boot, then assert reset while its NPU is active. The
        // following loop iteration must recover and complete a fresh boot.
        boot_ready=0; rst_ni=0; repeat(5) @(posedge clk); rst_ni=1; dmi_init();
        load_cpu_image(); boot_ready=1;
        wait_mailbox(32'h12345678); wait_npu_busy();
        // The foundry model may X memory on a reset-time timing notifier;
        // reload the CPU image after this reset exactly as ASIC boot ROM/SBA
        // would do on a fresh power-up.
        boot_ready=0; random_reset_during_busy(); boot_ready=1;
      end
    end
    $display("[SOC-ASIC-STRESS] PASS full SoC lanes=%0d boots=%0d, CPU/NPU macro SRAM, SBA=%0d, halt/resume=%0d",NPU_LANES,BOOT_ROUNDS,SBA_WORDS,HALT_ROUNDS);
    $finish;
  end
  initial begin #1000000000; $fatal(1,"ASIC full-SoC timeout"); end
endmodule
