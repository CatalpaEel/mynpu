`timescale 1ns/1ps
module tb_mnist;
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
  task automatic scalar_case(input int pixel,iz,oz,multiplier,bias,op,expected);
    wr(SRAM+'h400,op==1 ? 1 : 0);wr(SRAM+'h404,op==0 ? 1 : 0);wr(SRAM+'h408,0);
    wr(SRAM+'h420,multiplier);wr(SRAM+'h424,bias);wr(SRAM+'h1400,pixel);
    wr(SRAM+'h1800,32'hdeadbeef);
    wr(MMIO+'h608,SRAM+'h1400);wr(MMIO+'h60c,SRAM+'h400);wr(MMIO+'h610,SRAM+'h420);wr(MMIO+'h614,SRAM+'h1800);
    wr(MMIO+'h618,1);wr(MMIO+'h61c,1);wr(MMIO+'h620,1);wr(MMIO+'h624,1);
    wr(MMIO+'h628,1);wr(MMIO+'h62c,1);wr(MMIO+'h630,1);wr(MMIO+'h634,iz);wr(MMIO+'h638,oz);wr(MMIO+'h63c,op);
    wr(MMIO+'h600,1);wait_unit(MMIO+'h604);
    expect_word(SRAM+'h1800,32'hdeadbe00|32'(expected));
  endtask
  task automatic accumulator_bound(input logic [31:0] weight_word,input int expected);
    for(int i=0;i<36;i++)begin wr(SRAM+'h400+32'(i*4),weight_word);wr(SRAM+'h1400+32'(i*4),32'hffffffff);end
    wr(SRAM+'h500,256);wr(SRAM+'h504,0);wr(SRAM+'h1800,32'hdeadbeef);
    wr(MMIO+'h608,SRAM+'h1400);wr(MMIO+'h60c,SRAM+'h400);wr(MMIO+'h610,SRAM+'h500);wr(MMIO+'h614,SRAM+'h1800);
    wr(MMIO+'h618,144);wr(MMIO+'h61c,1);wr(MMIO+'h620,1);wr(MMIO+'h624,1);wr(MMIO+'h628,1);wr(MMIO+'h62c,1);wr(MMIO+'h630,1);
    wr(MMIO+'h634,0);wr(MMIO+'h638,128);wr(MMIO+'h63c,1);wr(MMIO+'h600,1);wait_unit(MMIO+'h604);
    expect_word(SRAM+'h1800,32'hdeadbe00|32'(expected));
  endtask
  task automatic edge_tests;
    logic [31:0] ignored;
    @(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;
    wr(MMIO+'h600,1);expect_word(MMIO+'h604,4);wr(MMIO+'h600,2);
    transfer(1,MMIO+'h604,0,4'hf,1,ignored);
    scalar_case(200,100,10,16777216,0,0,110);
    scalar_case(0,100,10,16777216,0,0,10);
    scalar_case(255,0,10,16777216,0,0,255);
    scalar_case(1,0,10,8388608,0,0,10);
    scalar_case(3,0,10,8388608,0,0,12);
    scalar_case(0,0,10,16777216,-8388608,1,10);
    scalar_case(0,0,10,16777216,-25165824,1,8);
    scalar_case(0,100,10,16777216,0,1,0);
    accumulator_bound(32'h7f7f7f7f,199);accumulator_bound(32'h80808080,56);
    wr(MMIO+'h618,32'hffffff01);wr(MMIO+'h600,1);expect_word(MMIO+'h604,4);
    wr(MMIO+'h618,1);wr(MMIO+'h614,SRAM+'h1400);wr(MMIO+'h600,1);expect_word(MMIO+'h604,4);
    $display("CNN boundary cases PASS (padding, byte masks, zero-points, ReLU, saturation, signed ties-even, invalid dimensions, overlap)");
  endtask
  initial begin
    logic [31:0] value,base,ignored;
    int limit,nsamples,cycle_count;
    logic [31:0] macs,issues,bus_count,waits;
    edge_tests();
    nsamples=10;limit=$value$plusargs("samples=%d",nsamples);
    if(nsamples<1 || nsamples>10)$fatal(1,"samples must be 1..10");
    for(int sample=0;sample<nsamples;sample++)begin
      @(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;
      dma_load("boot.hex",1024,SRAM);
      dma_load("params.hex",PARAM_BYTES,SRAM+'h400);
      dma_load($sformatf("input%0d.hex",sample),784,SRAM+'h1400);
      wr(SRAM+'h1f00,32'hffffffff);wr(SRAM+'h1f04,0);wr(SRAM+'h1f08,0);wr(SRAM+'h1f0c,1);
      wr(MMIO+8,1);
      if(sample==0)begin
        limit=0;
        do begin rd(MMIO+'h604,value);limit++;if(limit>10000)$fatal(1,"CNN did not start");end while(!value[0]);
        transfer(1,MMIO+'h618,0,4'hf,1,ignored);
        expect_word(MMIO+'h618,28);
        transfer(1,MMIO+'h600,1,4'hf,1,ignored);
        wr(MMIO+'h100,1);rd(MMIO+'h104,value);
        if(!value[2])$fatal(1,"Legacy matrix start was not rejected during CNN");
        $display("CNN busy descriptor protection / shared master exclusion PASS");
      end
      for(int layer=0;layer<6;layer++)begin
        limit=0;
        do begin
          rd(SRAM+'h1f04,value);limit++;
          if(cpu_done && !cpu_pass) $fatal(1,"CPU firmware failure");
          if(limit>200000) $fatal(1,"Layer timeout sample=%0d layer=%0d",sample,layer);
        end while(value!=layer+1);
        $readmemh($sformatf("gold%0d_%0d.hex",sample,layer),golden,0,layer_len[layer]-1);
        base=SRAM+(layer%2==0 ? 'h1800 : 'h1400);
        for(int i=0;i<layer_len[layer];i+=4)begin
          rd(base+32'(i),value);
          for(int b=0;b<4 && i+b<layer_len[layer];b++)begin
            if(value[b*8+:8]!==golden[i+b]) $fatal(1,"MNIST mismatch sample=%0d layer=%0d element=%0d got=%0d expected=%0d",sample,layer,i+b,value[b*8+:8],golden[i+b]);
            checks++;
          end
        end
        rd(MMIO+'h640,value);rd(MMIO+'h644,macs);rd(MMIO+'h648,issues);rd(MMIO+'h64c,bus_count);rd(MMIO+'h650,waits);
        if(macs!==expected_macs[layer] || issues!==expected_terms[layer])$fatal(1,"MAC counter mismatch layer=%0d macs=%0d issues=%0d",layer,macs,issues);
        $display("PERF sample=%0d layer=%0d cycles=%0d useful_macs=%0d issued=%0d bus=%0d wait=%0d utilization_pct=%0.2f",sample,layer,value,macs,issues,bus_count,waits,100.0*real'(macs)/real'(value));
        $display("sample=%0d layer=%0d bytes=%0d cycles=%0d PASS",sample,layer,layer_len[layer],value);
        wr(SRAM+'h1f08,layer+1);
      end
      limit=0;
      while(!cpu_done)begin @(negedge clk);limit++;if(limit>10000)$fatal(1,"CPU argmax timeout");end
      if(!cpu_pass)$fatal(1,"CPU failed");
      expect_word(SRAM+'h1f00,prediction[sample]);
      $display("MNIST sample=%0d prediction=%0d label=%0d PASS",sample,prediction[sample],sample);
    end
    // Normal execution: CPU advances without any layer ACK from the host.
    if(nsamples==10)begin
      @(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;
      dma_load("sram7.hex",8192,SRAM);
      wr(SRAM+'h1f00,32'hffffffff);wr(SRAM+'h1f04,0);wr(SRAM+'h1f08,0);wr(SRAM+'h1f0c,0);
      wr(MMIO+8,1);limit=0;
      while(!cpu_done)begin repeat(100)@(negedge clk);limit++;if(limit>10000)$fatal(1,"Normal mode timeout");end
      if(!cpu_pass)$fatal(1,"Normal mode CPU failed");
      expect_word(SRAM+'h1f00,7);expect_word(SRAM+'h1f04,6);
      $readmemh("gold7_5.hex",golden,0,9);
      for(int i=0;i<10;i+=4)begin
        rd(SRAM+'h1400+32'(i),value);
        for(int b=0;b<4 && i+b<10;b++)begin
          if(value[b*8+:8]!==golden[i+b])$fatal(1,"Normal mode logit mismatch");
          checks++;
        end
      end
      $display("MNIST normal mode without host layer ACK PASS prediction=7");
    end
    $display("MNIST PASS samples=%0d exact_activation_checks=%0d transactions=%0d",nsamples,checks,transactions);
    $finish;
  end
  initial begin #2000000000;$fatal(1,"Global timeout");end
endmodule
