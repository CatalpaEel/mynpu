`timescale 1ns/1ps
// All program, input, output and reset traffic goes through the physical JTAG pins.
// No internal forcing or simulation host backdoor is used.
module tb_validation;
  parameter integer FRAMES = 20, BOOTS = 2, BOARD_MHZ = 50;
  logic clk = 0, rst_n = 0, tck = 0, tms = 1, tdi = 0;
  wire tdo, halted;
`ifdef VALIDATION_ASIC
  always #(500.0/BOARD_MHZ) clk = ~clk;
  npu_soc dut (
    .clk_i(clk), .rst_ni(rst_n), .cpu_run_i(1'b1),
    .tck_i(tck), .tms_i(tms), .td_i(tdi), .td_o(tdo),
    .cpu_debug_halted_o(halted),
    .irq_o(), .cpu_test_done_o(), .cpu_test_pass_o()
  );
`else
  always #5 clk = ~clk;
  wire [7:0] leds;
  assign halted = leds[3];
  ego1_soc_top #(.SYSTEM_MHZ(BOARD_MHZ)) dut (.fpga_clk_i(clk), .rst_ni(rst_n), .tck_i(tck),
                   .tms_i(tms), .td_i(tdi), .td_o(tdo), .led_o(leds));
  time previous_clock_edge=0;
  always @(posedge dut.clk_sys)begin
    if(dut.sys_rst_ni && previous_clock_edge!=0 && $time-previous_clock_edge!=1000/BOARD_MHZ)
      $fatal(1,"Wrong FPGA system clock period");
    if(dut.sys_rst_ni)previous_clock_edge=$time;else previous_clock_edge=0;
  end
`endif
  `include "db_jtag_tasks.svh"
  `include "test_meta.svh"
  localparam logic [31:0] MAIL = 32'h80001fa0, PACKETS = 32'h80001c90;
  int checks = 0, checked_frames = 0;
  bit discard;
  logic [40:0] scan;
  logic [7:0] image[16384], inputs[10][784], golden[10];
  logic [31:0] value, packet[4];

  task automatic eq(input logic [31:0] got, wanted, input string label_text);
    if (got !== wanted) $fatal(1, "%s got=%h expected=%h", label_text, got, wanted);
    checks++;
  endtask
  task automatic halt_cpu;
    dmi_write('h10, 32'h80000001);
    for (int j=0; j<40; j++) begin
      dmi_read('h11, value);
      if (value[9]) return;
    end
    $fatal(1, "halt timeout");
  endtask
  task automatic resume_cpu;
    dmi_write('h10, 32'h40000001);
    for (int j=0; j<40; j++) begin
      dmi_read('h11, value);
      if (value[17]) begin dmi_write('h10, 1); return; end
    end
    $fatal(1, "resume timeout");
  endtask
  task automatic system_reset;
    dmi_write('h10, 1);
    dmi_write('h10, 3);
    dmi_write('h10, 32'h80000001);
    halt_cpu();
    sba_read(32'h40000008, value); eq(value, 0, "reset RUN");
    sba_read(32'h40000004, value); eq(value, 0, "reset result");
    sba_read(MAIL+8, value); // SRAM is retained, never assume it was cleared.
  endtask
  task automatic upload_image;
    dmi_write('h38, 32'h00050000);
    dmi_write('h39, 32'h80000000);
    for (int j=0; j<16384; j+=4)
      dmi_write('h3c, {image[j+3],image[j+2],image[j+1],image[j]});
    wait_sba();
    // Full 16KiB readback includes code, model and the physical bank boundary.
    // With the CPU halted there is no competing memory traffic. SBA read-on-
    // data/autoincrement checks every word without four DMI accesses per word.
    dmi_write('h38,32'h00158000);
    dmi_write('h39,32'h80000000);
    wait_sba();
    for (int j=0; j<16384; j+=4) begin
      if(j==16380)begin
        wait_sba();
        dmi_write('h38,32'h00150000); // No speculative read beyond the image.
      end
      dmi_read('h3c,value);
      eq(value, {image[j+3],image[j+2],image[j+1],image[j]}, "image readback");
    end
    wait_sba();
    dmi_write('h38,32'h00040000);
    $display("VALIDATION IMAGE full 16KiB upload/readback PASS");
  endtask
  task automatic supply_input(input int sample, slot);
    logic [31:0] base_addr;
    base_addr = slot == 0 ? 32'h80001360 : 32'h80001980;
    dmi_write('h38, 32'h00050000);
    dmi_write('h39, base_addr);
    for (int j=0; j<784; j+=4) begin
      if (j%64==0) idle_ticks($urandom_range(0,7));
      dmi_write('h3c, {inputs[sample][j+3],inputs[sample][j+2],
                      inputs[sample][j+1],inputs[sample][j]});
    end
    wait_sba();
    sba_read(base_addr, value);
    eq(value, {inputs[sample][3],inputs[sample][2],inputs[sample][1],inputs[sample][0]}, "input first");
  endtask
  initial begin
    int sample, slot;
    if (FRAMES<2 || BOOTS<1) $fatal(1, "Need at least two frames per boot");
    $readmemh("stream_sram.hex", image);
    for (int n=0; n<10; n++) begin
      logic [7:0] temp[784];
      $readmemh($sformatf("input%0d.hex", n), temp);
      for (int j=0; j<784; j++) inputs[n][j]=temp[j];
    end
    #200;
    rst_n=1;
`ifndef VALIDATION_ASIC
    wait(dut.sys_rst_ni);
`endif
    repeat(8) tick(1,0,discard);
    tick(0,0,discard); select_ir(1); scan_dr(32,0,scan);
    eq(scan[31:0],1,"IDCODE"); select_ir('h11);
    for(int boot=0; boot<BOOTS; boot++) begin
      system_reset();
      upload_image();
      // Clear ownership and completion fields explicitly after the verified load.
      for(int n=0;n<16;n++)sba_write(MAIL+n*4,0);
      sba_write(MAIL+24,FRAMES);
      sba_write(32'h40000004,0);
      sba_write(32'h4000000c,32'h80000080);
      sba_write(32'h40000008,1);
      resume_cpu();
      for(int frame=0;frame<FRAMES;frame++)begin
        sample=(frame*7+boot)%10; slot=frame%2;
        supply_input(sample,slot);
        sba_write(MAIL+slot*4,frame+1);
        // CPU halt does not halt the accelerators. Completion must remain
        // observable when the CPU resumes its ticket/IRQ/WFI waiting code.
        if(frame==1)begin halt_cpu();idle_ticks(37);resume_cpu();end
        for(int poll=0;poll<200;poll++)begin
          sba_read(MAIL+8+slot*4,value);
          if(value==frame+1)break;
          if(poll==199)$fatal(1,"DONE timeout boot=%0d frame=%0d",boot,frame);
          sba_read(32'h40000004,value);
          if(value!=0)begin
            // The final DONE may commit between the two SBA reads. Verify it
            // again before interpreting terminal PASS as an early exit.
            if(value==32'h600d0001 && frame==FRAMES-1)begin
              sba_read(MAIL+8+slot*4,value);
              if(value==frame+1)begin
                $display("VALIDATION final DONE/status race resolved");
                break;
              end
            end
            $fatal(1,"Unexpected firmware status %h",value);
          end
          idle_ticks($urandom_range(0,11));
        end
        $readmemh($sformatf("gold%0d_5.hex",sample),golden);
        for(int n=0;n<4;n++)sba_read(PACKETS+slot*16+n*4,packet[n]);
        for(int n=0;n<10;n++)eq((packet[n/4]>>((n%4)*8))&255,golden[n],"integer logit");
        eq(packet[3],prediction[sample],"packet argmax");
        sba_read(MAIL+16+slot*4,value);eq(value,prediction[sample],"mail argmax");
        sba_read(MAIL+8+slot*4,value);eq(value,frame+1,"stable DONE sequence");
        checked_frames++;
        $display("VALIDATION FRAME boot=%0d frame=%0d sample=%0d PASS",boot,frame,sample);
      end
      sba_read(32'h40000004,value);eq(value,32'h600d0001,"whole batch success");
      sba_read(32'h40000128,value);eq(value,13*FRAMES,"Matrix completed tickets across frames");
      sba_read(32'h4000065c,value);eq(value,STREAM_TASKS*FRAMES,"CNN completed tickets across frames");
      // POR also resets the TAP. Exercise a fresh IDCODE/DM activation on the
      // next round, rather than silently reusing a stale debug session.
      if(boot+1<BOOTS)begin
        rst_n=0;#200;rst_n=1;
`ifndef VALIDATION_ASIC
        wait(dut.sys_rst_ni);
`endif
        repeat(8)tick(1,0,discard);tick(0,0,discard);
        select_ir(1);scan_dr(32,0,scan);eq(scan[31:0],1,"IDCODE after POR");select_ir('h11);
      end
    end
    // System reset after a successful batch must clear stale success, while
    // SRAM persists. A new image must be loaded before starting another run.
    system_reset();
    $display("EGO1 STRESS PASS frames=%0d boots=%0d checks=%0d",checked_frames,BOOTS,checks);
    $finish;
  end
  initial begin #2000000000;$fatal(1,"global timeout");end
endmodule
