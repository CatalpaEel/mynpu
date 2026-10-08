`timescale 1ns/1ps
module tb_mnist_stream;
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

  localparam logic [31:0] A=SRAM+'h1360,C=SRAM+'h1980,PACKETS=SRAM+'h1c90,MAIL=SRAM+'h1fa0;
  longint clock_count=0,kernel_cycles=0,mac_clocks=0;
  int rx_compute_overlap=0,tx_compute_overlap=0;
  always @(posedge clk)begin
    clock_count++;
    if(rst_n)begin
      if(dut.i_core.cnn_busy)kernel_cycles++;
      if(dut.i_core.i_cnn.tap_valid && dut.i_core.i_cnn.tap_inside)mac_clocks++;
      if(rx_valid && rx_ready && dut.i_core.cnn_busy)rx_compute_overlap++;
      if(tx_valid && tx_ready && dut.i_core.cnn_busy)tx_compute_overlap++;
    end
  end
  task automatic packet(input int frame);
    logic [31:0] expected;
    int waited;
    $readmemh($sformatf("gold%0d_5.hex",frame%10),golden,0,9);
    wr(MMIO+'h408,PACKETS+32'((frame%2)*16));wr(MMIO+'h410,16);wr(MMIO+'h414,1);
    wr(MMIO+'h418,0);wr(MMIO+'h41c,0);wr(MMIO+'h420,1);wr(MMIO+'h434,10000);wr(MMIO+'h400,1);
    for(int word_no=0;word_no<4;word_no++)begin
      expected=0;
      if(word_no==3)expected=prediction[frame%10];
      else for(int b=0;b<4;b++)if(word_no*4+b<10)expected[b*8+:8]=golden[word_no*4+b];
      @(negedge clk);tx_ready=0;waited=0;
      while(!tx_valid)begin @(negedge clk);waited++;if(waited>1000)$fatal(1,"TX packet stalled");end
      repeat(word_no%3)@(negedge clk);
      if(tx_data!==expected || tx_keep!==4'hf || tx_last!==(word_no==3))$fatal(1,"Stream packet mismatch frame=%0d word=%0d got=%h expected=%h",frame,word_no,tx_data,expected);
      tx_ready=1;@(posedge clk);@(negedge clk);tx_ready=0;checks++;
    end
    wait_unit(MMIO+'h404);
  endtask
  initial begin
    int frames,ignored_plusarg,limit,expected_total;
    logic [31:0] value,cycle_sum,mac_sum;
    longint start_clock,elapsed;
    frames=20;ignored_plusarg=$value$plusargs("frames=%d",frames);
    if(frames<2 || frames>1000)$fatal(1,"frames must be 2..1000");
    repeat(5)@(negedge clk);rst_n=1;
    dma_load("stream_boot.hex",1024,SRAM);dma_load("params.hex",PARAM_BYTES,SRAM+'h400);
    dma_load("input0.hex",784,A);dma_load("input1.hex",784,C);
    for(int off=0;off<40;off+=4)wr(MAIL+32'(off),0);
    wr(MAIL,1);wr(MAIL+4,2);wr(MAIL+24,frames);
    start_clock=clock_count;wr(MMIO+8,1);
    for(int frame=0;frame<frames;frame++)begin
      limit=0;
      do begin
        rd(MAIL+8+32'((frame%2)*4),value);limit++;
        if(cpu_done && !cpu_pass)$fatal(1,"Stream firmware error");
        if(limit>20000)$fatal(1,"Stream timeout frame=%0d",frame);
        if(value!=frame+1)repeat(32)@(negedge clk);
      end while(value!=frame+1);
      if(frame+1<frames)begin
        limit=0;
        do begin rd(MMIO+'h604,value);limit++;if(limit>2000)$fatal(1,"Next inference did not start");end while(!value[0]);
      end
      packet(frame);expect_word(MAIL+16+32'((frame%2)*4),prediction[frame%10]);
      if(frame+2<frames)begin
        dma_load($sformatf("input%0d.hex",(frame+2)%10),784,frame%2==0 ? A : C);
        wr(MAIL+32'((frame%2)*4),frame+3);
      end
      $display("STREAM frame=%0d slot=%0d prediction=%0d logits and TX PASS",frame,frame%2,prediction[frame%10]);
    end
    limit=0;while(!cpu_done)begin @(negedge clk);limit++;if(limit>10000)$fatal(1,"Stream completion timeout");end
    if(!cpu_pass)$fatal(1,"Stream failed");
    elapsed=clock_count-start_clock;rd(MAIL+32,cycle_sum);rd(MAIL+36,mac_sum);
    expected_total=0;for(int i=0;i<6;i++)expected_total+=expected_macs[i];expected_total*=frames;
    if(mac_sum!==32'(expected_total) || mac_clocks!=expected_total || kernel_cycles!=cycle_sum)$fatal(1,"Stream accounting mismatch MAC=%0d monitor=%0d cycles=%0d monitor=%0d",mac_sum,mac_clocks,cycle_sum,kernel_cycles);
    if(rx_compute_overlap==0 || tx_compute_overlap==0)$fatal(1,"No DMA/compute overlap");
    $display("STREAM PASS frames=%0d useful_macs=%0d kernel_cycles=%0d elapsed_cycles=%0d kernel_utilization_pct=%0.2f system_utilization_pct=%0.2f rx_overlap_beats=%0d tx_overlap_beats=%0d checks=%0d",frames,mac_sum,cycle_sum,elapsed,100.0*real'(mac_sum)/real'(cycle_sum),100.0*real'(mac_sum)/real'(elapsed),rx_compute_overlap,tx_compute_overlap,checks);
    $finish;
  end
  initial begin #20000000000;$fatal(1,"Stream global timeout");end
endmodule
