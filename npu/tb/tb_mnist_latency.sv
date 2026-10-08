`timescale 1ns/1ps
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
  logic rx_valid=0,rx_last=0,tx_ready=0;
  logic [31:0] rx_data=0;
  logic [3:0] rx_keep=4'hf;
  wire rx_ready,rx_abort,tx_valid,tx_last,tx_abort;
  wire [31:0] tx_data;
  wire [3:0] tx_keep;
  logic [31:0] boot_image[0:511];
  wire cpu_done, cpu_pass;
  localparam logic [31:0] SRAM = 32'h80000000, MMIO = 32'h40000000;
  npu_soc dut (
    .clk_i(clk), .rst_ni(rst_n), .cpu_run_i(cpu_run),
    .host_req_i(hreq), .host_we_i(hwe), .host_be_i(hbe),
    .host_addr_i(haddr), .host_wdata_i(hwdata), .host_gnt_o(hgnt),
    .dma_rx_valid_i(rx_valid),.dma_rx_ready_o(rx_ready),.dma_rx_data_i(rx_data),
    .dma_rx_keep_i(rx_keep),.dma_rx_last_i(rx_last),.dma_rx_abort_o(rx_abort),
    .dma_tx_valid_o(tx_valid),.dma_tx_ready_i(tx_ready),.dma_tx_data_o(tx_data),
    .dma_tx_keep_o(tx_keep),.dma_tx_last_o(tx_last),.dma_tx_abort_o(tx_abort),
    .host_rvalid_o(hrvalid), .host_error_o(herror), .host_rdata_o(hrdata),
    .irq_o(irq), .cpu_test_done_o(cpu_done), .cpu_test_pass_o(cpu_pass)
  );
  int checks = 0, transactions = 0, mat_jobs = 0;
  int max_host_wait = 0;
  int rx_aborts=0,tx_aborts=0;
  always @(posedge clk) begin
    if(rx_abort) rx_aborts++;
    if(tx_abort) tx_aborts++;
  end
  task automatic transfer(input bit wr, input logic [31:0] a, d,
                          input logic [3:0] mask, input bit expected_error,
                          output logic [31:0] result);
    int waited;
    @(negedge clk);
    hreq = 1; hwe = wr; haddr = a; hwdata = d; hbe = mask;
    waited = 0;
    do begin
      @(posedge clk);
      waited++;
      if (waited > 16) $fatal(1,"Host starved, addr=%h",a);
    end while (!hgnt);
    if (waited > max_host_wait) max_host_wait = waited;
    @(negedge clk);
    hreq = 0;
    if (!hrvalid) @(negedge clk); // Registered MMIO responds one cycle after SRAM.
    if (!hrvalid) $fatal(1,"Missing response addr=%h",a);
    if (herror !== expected_error) $fatal(1,"Bus error addr=%h got=%b expected=%b",a,herror,expected_error);
    result = hrdata; transactions++;
  endtask
  task automatic wr(input logic [31:0] a,d);
    logic [31:0] ignored;
    transfer(1,a,d,4'hf,0,ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    transfer(0,a,0,4'hf,0,d);
  endtask
  task automatic expect_word(input logic [31:0] a,d);
    logic [31:0] got;
    rd(a,got);
    if (got !== d) $fatal(1,"Mismatch addr=%h got=%h expected=%h",a,got,d);
    checks++;
  endtask
  task automatic wait_unit(input logic [31:0] status_addr, input bit allow_error = 0);
    logic [31:0] s;
    bit finished;
    finished = 0;
    for (int t = 0; t < 40000 && !finished; t++) begin
      rd(status_addr,s);
      if (s[2] && !allow_error) $fatal(1,"Unexpected command error status=%h",s);
      finished = s[1] && !s[0];
    end
    if (!finished) $fatal(1,"Unit timeout %h",status_addr);
    checks++;
  endtask

  `include "test_meta.svh"
  logic [7:0] payload[8192];
  logic [7:0] golden[784];
  task automatic dma_load(input string filename,input int count,input logic [31:0] destination);
    logic [31:0] word;
    logic [3:0] keep;
    int waited;
    $readmemh(filename,payload,0,count-1);
    wr(MMIO+'h30c,destination);wr(MMIO+'h310,count);wr(MMIO+'h314,1);
    wr(MMIO+'h318,0);wr(MMIO+'h31c,0);wr(MMIO+'h320,0);wr(MMIO+'h334,0);wr(MMIO+'h300,1);
    for(int i=0;i<count;i+=4)begin
      word=0;keep=0;
      for(int b=0;b<4 && i+b<count;b++)begin word[b*8+:8]=payload[i+b];keep[b]=1;end
      @(negedge clk);rx_valid=1;rx_data=word;rx_keep=keep;rx_last=i+4>=count;
      waited=0;
      do begin @(posedge clk);waited++;if(waited>100) $fatal(1,"DMA RX timeout");end while(!rx_ready);
      @(negedge clk);rx_valid=0;
    end
    wait_unit(MMIO+'h304);
  endtask
  bit measure=0;
  longint elapsed=0,kernel=0,macs=0;
  int jobs=0;
  bit previous_busy=0;
  always @(posedge clk) begin
    if(measure) begin
      elapsed++;
      if(dut.i_core.cnn_busy) kernel++;
      if(dut.i_core.i_cnn.tap_valid && dut.i_core.i_cnn.tap_inside) macs++;
      if(previous_busy && !dut.i_core.cnn_busy) jobs++;
      previous_busy=dut.i_core.cnn_busy;
    end
  end
  initial begin
    logic [31:0] value;
    int limit;
    longint ingress_cycles,total_cycles;
    for(int sample=0;sample<10;sample++)begin
      measure=0;
      @(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;
      dma_load("boot.hex",1024,SRAM);dma_load("params.hex",PARAM_BYTES,SRAM+'h400);
      wr(SRAM+'h1f00,32'hffffffff);wr(SRAM+'h1f04,0);wr(SRAM+'h1f08,0);wr(SRAM+'h1f0c,0);
      elapsed=0;kernel=0;macs=0;jobs=0;previous_busy=0;measure=1;
      dma_load($sformatf("input%0d.hex",sample),784,SRAM+'h1400);
      ingress_cycles=elapsed;
      wr(MMIO+8,1);limit=0;
      // No host polling, per-layer ACK or competing image DMA during inference.
      while(!cpu_done)begin @(negedge clk);limit++;if(limit>100000)$fatal(1,"Single inference timeout");end
      measure=0;total_cycles=elapsed;elapsed-=ingress_cycles;
      if(!cpu_pass || jobs!=6 || macs!=40770)$fatal(1,"Single accounting/result failed jobs=%0d macs=%0d",jobs,macs);
      expect_word(SRAM+'h1f00,prediction[sample]);expect_word(SRAM+'h1f04,6);
      $readmemh($sformatf("gold%0d_5.hex",sample),golden,0,9);
      for(int i=0;i<10;i+=4)begin
        rd(SRAM+'h1400+32'(i),value);
        for(int b=0;b<4 && i+b<10;b++)begin
          if(value[b*8+:8]!==golden[i+b])$fatal(1,"Single logits mismatch sample=%0d element=%0d",sample,i+b);
          checks++;
        end
      end
      $display("SINGLE_INPUT sample=%0d ingress_cycles=%0d input_to_classification_cycles=%0d input_to_classification_us_at_50mhz=%0.2f PASS",sample,ingress_cycles,total_cycles,real'(total_cycles)/50.0);
      $display("SINGLE sample=%0d useful_macs=%0d kernel_cycles=%0d elapsed_cycles=%0d kernel_utilization_pct=%0.2f system_utilization_pct=%0.2f latency_us_at_50mhz=%0.2f PASS",sample,macs,kernel,elapsed,100.0*real'(macs)/real'(kernel),100.0*real'(macs)/real'(elapsed),real'(elapsed)/50.0);
    end
    $display("SINGLE PASS samples=10 checks=%0d",checks);$finish;
  end
  initial begin #2000000000;$fatal(1,"Global timeout");end
endmodule
