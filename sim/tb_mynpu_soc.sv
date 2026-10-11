`timescale 1ns/1ps
module tb_mynpu_soc #(
  parameter integer LANES = 8,
  parameter integer NPU_SRAM_BYTES = 8192,
  parameter integer INFERENCE_RUNS = 5,
  parameter bit STRESS_MODE = 1'b0,
  parameter integer STRESS_SBA_WORDS = 32,
  parameter integer STRESS_HALT_ROUNDS = 3
);
  localparam CPU_IMAGE = (NPU_SRAM_BYTES == 8192) ? "generated/8k/cpu.hex" : "generated/16k/cpu.hex";
  localparam GOLDEN_IMAGE = (NPU_SRAM_BYTES == 8192) ? "generated/8k/integer_layers.hex" : "generated/16k/integer_layers.hex";
  localparam PYTORCH_IMAGE = (NPU_SRAM_BYTES == 8192) ? "generated/8k/pytorch_layers.hex" : "generated/16k/pytorch_layers.hex";
  logic clk=0, rst_n=0, boot_ready=0;
  logic tck=0, tms=1, tdi=0, tdo, npu_irq, debug_halted;
  logic [7:0] golden [0:1793];
  logic [7:0] pytorch_golden [0:1793];
  integer layer_checks=0, irq_edges=0;
  integer previous_state=-1, previous_layer=0;
  integer offset, count, actual, delta, i;
  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(NPU_SRAM_BYTES),
    .NPU_LANES(LANES), .CPU_INIT_FILE(CPU_IMAGE), .NPU_INIT_FILE("")
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_ready_i(boot_ready),
    .tck_i(tck), .tms_i(tms), .td_i(tdi), .td_o(tdo),
    .npu_irq_o(npu_irq), .cpu_debug_halted_o(debug_halted)
  );
  always #5 clk=~clk;
  always @(posedge npu_irq) irq_edges++;
  initial begin
    $readmemh(GOLDEN_IMAGE, golden);
    $readmemh(PYTORCH_IMAGE, pytorch_golden);
    for (integer j=0;j<1794;j++)
      if ($isunknown(golden[j]) || $isunknown(pytorch_golden[j]))
        $fatal(1,"Missing golden data at byte %0d",j);
  end

  // Compare every layer before ping-pong buffers are reused by the next layer.
  always @(negedge clk) begin
    if (previous_state == 5 &&
        (dut.i_npu_subsystem.g_functional.i_core.state_q == 1 || dut.i_npu_subsystem.g_functional.i_core.state_q == 6)) begin
      case (previous_layer)
        0: begin offset=0; count=392; end
        1: begin offset=392; count=784; end
        2: begin offset=1176; count=392; end
        3: begin offset=1568; count=72; end
        4: begin offset=1640; count=144; end
        5: begin offset=1784; count=10; end
        default: $fatal(1, "Invalid layer");
      endcase
      for (i=0;i<count;i++) begin
        actual=dut.i_npu_subsystem.g_functional.i_core.mem[dut.i_npu_subsystem.g_functional.i_core.out_base_q+i];
        if (actual !== golden[offset+i])
          $fatal(1, "Layer %0d byte %0d integer mismatch hw=%0d ref=%0d", previous_layer, i, actual, golden[offset+i]);
        delta=actual-integer'(pytorch_golden[offset+i]);
        if (delta < -1 || delta > 1)
          $fatal(1,"Layer %0d byte %0d PyTorch mismatch hw=%0d ref=%0d",previous_layer,i,actual,pytorch_golden[offset+i]);
      end
      layer_checks++;
      $display("[SOC] layer %0d exact integer + PyTorch delta <= 1: %0d bytes", previous_layer, count);
    end
    previous_state=dut.i_npu_subsystem.g_functional.i_core.state_q;
    previous_layer=dut.i_npu_subsystem.g_functional.i_core.layer_q;
  end

  task automatic tick(input bit ms, input bit di, output bit sample);
    tck=0; tms=ms; tdi=di; #20;
    sample=tdo; tck=1; #20;
  endtask
  task automatic idle_ticks(input integer n);
    bit discard;
    repeat(n) tick(0,0,discard);
  endtask
  task automatic select_ir(input logic [4:0] ir);
    bit discard;
    tick(1,0,discard); tick(1,0,discard); tick(0,0,discard); tick(0,0,discard);
    for (integer j=0;j<5;j++) tick(j==4,ir[j],discard);
    tick(1,0,discard); tick(0,0,discard);
  endtask
  task automatic scan_dr(input integer n, input logic [40:0] tx, output logic [40:0] rx);
    bit sample;
    tick(1,0,sample); tick(0,0,sample); tick(0,0,sample);
    rx=0;
    for (integer j=0;j<n;j++) begin tick(j==n-1,tx[j],sample); rx[j]=sample; end
    tick(1,0,sample); tick(0,0,sample);
  endtask
  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,data,2'b10},response);
    idle_ticks(64);
    scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI write failed addr=%h status=%h",addr,response[1:0]);
  endtask
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,32'd0,2'b01},response);
    idle_ticks(64);
    scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI read failed addr=%h status=%h",addr,response[1:0]);
    data=response[33:2];
  endtask
  task automatic wait_sba;
    logic [31:0] status;
    integer j;
    for(j=0;j<30;j++) begin
      dmi_read(7'h38,status);
      if (status[14:12] || status[22]) $fatal(1,"SBA error %h",status);
      if (!status[21]) return;
    end
    $fatal(1,"SBA timeout");
  endtask
  task automatic sba_write(input logic [31:0] addr, input logic [31:0] data);
    dmi_write(7'h38,32'h00040000); // 32-bit access, disable read-on-address/data
    dmi_write(7'h39,addr);
    dmi_write(7'h3c,data);
    wait_sba();
  endtask
  task automatic sba_read(input logic [31:0] addr, output logic [31:0] data);
    dmi_write(7'h38,32'h00140000); // 32-bit access, read-on-address
    dmi_write(7'h39,addr);
    wait_sba();
    dmi_read(7'h3c,data);
  endtask
  task automatic wait_abstract;
    logic [31:0] status;
    for(integer j=0;j<50;j++) begin
      dmi_read(7'h16,status);
      if (status[10:8]) $fatal(1,"Abstract command error %h",status);
      if (!status[12]) return;
    end
    $fatal(1,"Abstract command timeout");
  endtask

  logic [31:0] value, saved_register, expected_stress;
  logic stress_done;
  logic [40:0] scan_response;
  bit discard;
  initial begin
    repeat(10) @(posedge clk);
    @(negedge clk) rst_n=1;
    repeat(10) @(posedge clk);
    // Exercise asynchronous reset assertion and synchronous release before
    // any debug transaction. This catches stale DMI/AXI state at boot.
    if (STRESS_MODE) begin
      repeat (2) begin
        @(negedge clk) rst_n=1'b0;
        repeat(3) @(posedge clk);
        @(negedge clk) rst_n=1'b1;
        repeat(4) @(posedge clk);
      end
    end
    repeat(6) tick(1,0,discard);
    tick(0,0,discard);
    select_ir(5'h01);
    scan_dr(32,0,scan_response);
    if (scan_response[31:0] !== 32'h00000001) $fatal(1,"JTAG IDCODE mismatch %h",scan_response);
    select_ir(5'h11);
    dmi_write(7'h10,32'd1);
    sba_write(32'h80001ffc,32'h1234abcd);
    sba_read(32'h80001ffc,value);
    if (value !== 32'h1234abcd) $fatal(1,"CPU SRAM SBA mismatch %h",value);
    sba_write(32'h70005ffc,32'h89abcdef);
    sba_read(32'h70005ffc,value);
    if (value !== 32'h89abcdef) $fatal(1,"NPU SRAM SBA mismatch %h",value);
    $display("[SOC] JTAG DMI + SBA CPU/NPU read/write passed");

    // Fill and read back a larger NPU SRAM window through the real DMI/SBA
    // path. The firmware overwrites this area later, so it does not affect
    // the model image. This also stresses back-to-back SBA completion.
    if (STRESS_MODE) begin
      for (integer k=0; k<STRESS_SBA_WORDS; k=k+1) begin
        expected_stress = 32'ha5000000 ^ (k * 32'h01020305);
        sba_write(32'h70004000 + k*4, expected_stress);
        sba_read(32'h70004000 + k*4, value);
        if (value !== expected_stress)
          $fatal(1,"Stress NPU SBA mismatch word=%0d hw=%h ref=%h",k,value,expected_stress);
      end
      $display("[SOC-STRESS] %0d NPU SRAM SBA words passed", STRESS_SBA_WORDS);

      // Malformed control/descriptor inputs must fail cleanly instead of
      // wrapping a physical SRAM address or looping forever on a zero-sized
      // tensor. The firmware later restores the valid configuration.
      sba_write(32'h70000014,32'h000000ff); // layer count > MAX_LAYERS
      sba_write(32'h70000000,32'h00000001);
      value=0;
      for (integer k=0; k<20; k=k+1) begin
        sba_read(32'h70000004,value);
        if (value[2]) break;
      end
      if (!value[2]) $fatal(1,"Stress invalid layer count did not set ERROR");
      sba_write(32'h70000000,32'h00000004); // clear error
      sba_read(32'h70000004,value);
      if (value[2]) $fatal(1,"Stress layer-count ERROR did not clear status=%h",value);

      sba_write(32'h70000014,32'h00000006);
      sba_write(32'h70000010,32'h00001ffc); // descriptor region out of SRAM
      sba_write(32'h70000000,32'h00000001);
      value=0;
      for (integer k=0; k<20; k=k+1) begin
        sba_read(32'h70000004,value);
        if (value[2]) break;
      end
      if (!value[2]) $fatal(1,"Stress invalid descriptor base did not set ERROR");
      sba_write(32'h70000000,32'h00000004); // restore idle/error state
      sba_read(32'h70000004,value);
      if (value[2]) $fatal(1,"Stress descriptor ERROR did not clear status=%h",value);
      $display("[SOC-STRESS] invalid layer/descriptor inputs rejected");
    end

    @(negedge clk) boot_ready=1;
    wait(dut.i_mainmem.mem['h1fc0/4] === 32'h12345678);
    dmi_write(7'h10,32'h80000001); // halt request
    for(integer j=0;j<50;j++) begin
      dmi_read(7'h11,value);
      if (value[9]) break;
      if (j==49) $fatal(1,"CPU halt timeout %h",value);
    end
    if (!debug_halted) $fatal(1,"CPU debug mode not entered");
    dmi_write(7'h17,32'h0022101f); // read x31
    wait_abstract(); dmi_read(7'h04,saved_register);
    dmi_write(7'h04,32'h5a123456);
    dmi_write(7'h17,32'h0023101f); // write x31
    wait_abstract();
    dmi_write(7'h17,32'h0022101f); wait_abstract(); dmi_read(7'h04,value);
    if (value !== 32'h5a123456) $fatal(1,"CPU register debug mismatch %h",value);
    dmi_write(7'h04,saved_register);
    dmi_write(7'h17,32'h0023101f); wait_abstract();
    // Halt and resume the CPU while the NPU is running. SBA remains usable
    // while the hart is halted, and the NPU must continue without corrupting
    // its state. The normal firmware later checks every output and IRQ.
    if (STRESS_MODE) begin
      stress_done=1'b0;
      fork : stress_halt_worker
        begin : stress_halt_body
          integer wait_cycles;
          for (integer k=0; k<STRESS_HALT_ROUNDS; k=k+1) begin
            wait_cycles=0;
            while ((dut.i_npu_subsystem.g_functional.i_core.busy_q !== 1'b1) &&
                   (wait_cycles < 200000)) begin
              @(posedge clk);
              wait_cycles=wait_cycles+1;
            end
            if (dut.i_npu_subsystem.g_functional.i_core.busy_q !== 1'b1)
              $fatal(1,"Stress timeout waiting for NPU busy round=%0d mailbox=%h fail=%h handled=%h npu=%b%b%b irq=%0d state=%0d",k,
                     dut.i_mainmem.mem['h1fc0/4],dut.i_mainmem.mem['h1fc4/4],dut.i_mainmem.mem['h1ff8/4],
                     dut.i_npu_subsystem.g_functional.i_core.busy_q,
                     dut.i_npu_subsystem.g_functional.i_core.done_q,
                     dut.i_npu_subsystem.g_functional.i_core.error_q,
                     dut.i_npu_subsystem.g_functional.i_core.irq_en_q,
                     dut.i_npu_subsystem.g_functional.i_core.state_q);

            dmi_write(7'h10,32'h80000001); // halt request
            for (integer j=0;j<80;j=j+1) begin
              dmi_read(7'h11,value);
              if (value[9]) break;
              if (j==79) $fatal(1,"Stress CPU halt timeout round=%0d",k);
            end
            if (!debug_halted) $fatal(1,"Stress debug halt output missing round=%0d",k);
            sba_read(32'h70000004,value); // NPU STATUS while CPU is halted
            dmi_write(7'h10,32'h40000001); // resume request
            for (integer j=0;j<80;j=j+1) begin
              dmi_read(7'h11,value);
              if (!value[9]) break;
              if (j==79) $fatal(1,"Stress CPU resume timeout round=%0d",k);
            end
        end
          stress_done=1'b1;
        end
      join_none
    end
    dmi_write(7'h10,32'h40000001); // resume request
    $display("[SOC] CPU halt/register read-write/resume passed");
    if (STRESS_MODE) begin
      wait(stress_done);
      $display("[SOC-STRESS] %0d halt/resume rounds during NPU activity passed", STRESS_HALT_ROUNDS);
    end

    wait(dut.i_mainmem.mem['h1fc0/4] === 32'hc0dec0de || dut.i_mainmem.mem['h1fc0/4] === 32'hdeadbeef);
    if (dut.i_mainmem.mem['h1fc0/4] === 32'hdeadbeef)
      $fatal(1,"CPU firmware failed code=%h",dut.i_mainmem.mem['h1fc4/4]);
    if (layer_checks != 6*INFERENCE_RUNS || irq_edges != INFERENCE_RUNS-1 || dut.i_mainmem.mem['h1ff8/4] != INFERENCE_RUNS-1)
      $fatal(1,"Coverage mismatch layers=%0d irq=%0d handled=%0d",layer_checks,irq_edges,dut.i_mainmem.mem['h1ff8/4]);
    $display("[SOC] PASS lanes=%0d npu_sram=%0d: CPU boot, JTAG/SBA, %0d repeated runs (%0d exact layers), polling + CPU IRQ, cycles=%0d",LANES,NPU_SRAM_BYTES,INFERENCE_RUNS,layer_checks,dut.i_mainmem.mem['h1fcc/4]);
    $finish;
  end
  initial begin #50000000; $fatal(1,"Global SoC timeout"); end
endmodule
