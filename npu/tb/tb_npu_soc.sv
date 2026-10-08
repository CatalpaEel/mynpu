`timescale 1ns/1ps
module tb_npu_soc;
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
      if (waited > 8) $fatal(1,"Host starved, addr=%h",a);
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
  task automatic mat_config(input int m,n,k);
    wr(MMIO+'h108,SRAM); wr(MMIO+'h10c,SRAM+'h400); wr(MMIO+'h110,SRAM+'h800);
    wr(MMIO+'h114,32'(m)); wr(MMIO+'h118,32'(n)); wr(MMIO+'h11c,32'(k));
  endtask
  task automatic mat_test(input int m,n,k,seed, input bit concurrent_vec=0, mutate=0);
    int av[256], bv[256], expected, value;
    logic [31:0] ignored,s;
    for(int i=0;i<m*k;i++) begin
      av[i] = ((i*17 + seed*3)%256)-128;
      wr(SRAM+32'(i*4),32'(av[i]));
    end
    for(int i=0;i<k*n;i++) begin
      bv[i] = ((i*29 + seed*5)%256)-128;
      wr(SRAM+'h400+32'(i*4),32'(bv[i]));
    end
    mat_config(m,n,k);
    if(concurrent_vec) begin
      for(int i=0;i<64;i++) wr(SRAM+'h1000+32'(i*4),32'((i%2 != 0) ? -i : i));
      wr(MMIO+'h208,SRAM+'h1000); wr(MMIO+'h20c,SRAM+'h1400);
      wr(MMIO+'h210,64); wr(MMIO+'h214,0);
      for(int i=0;i<32;i++) begin
        wr(SRAM+'hd00+32'(4*i),32'h55aa0000|32'(i));
        wr(SRAM+'he00+32'(4*i),32'hdead0000|32'(i));
      end
      dma_config(0,0,SRAM+'hc00,128,1,0,128,0);
      dma_config(1,SRAM+'hd00,0,128,1,128,0,1);
      dma_config(2,SRAM+'he00,SRAM+'hf00,128,1,128,128,2);
    end
    wr(MMIO+'h100,1);
    if(concurrent_vec) begin
      wr(MMIO+'h200,1);wr(MMIO+'h300,1);wr(MMIO+'h400,1);wr(MMIO+'h500,1);
    end
    if(mutate) begin
      // Descriptor writes and restart must be rejected while the running job survives.
      transfer(1,MMIO+'h114,1,4'hf,1,ignored);
      wr(MMIO+'h100,1);
    end
    if(concurrent_vec) begin
      fork
        begin
          for(int i=0;i<32;i++) rx_beat(32'h12340000|32'(i),4'hf,i==31,i%3);
        end
        begin
          for(int i=0;i<32;i++) tx_beat(32'h55aa0000|32'(i),4'hf,i==31,i%4);
        end
        begin
          for(int i=0;i<64;i++) begin
            wr(SRAM+'h1f00,32'(i));expect_word(SRAM+'h1f00,32'(i));
          end
        end
      join
      wait_unit(MMIO+'h304);wait_unit(MMIO+'h404);wait_unit(MMIO+'h504);
      for(int i=0;i<32;i++) begin
        expect_word(SRAM+'hc00+32'(4*i),32'h12340000|32'(i));
        expect_word(SRAM+'hf00+32'(4*i),32'hdead0000|32'(i));
      end
      wait_unit(MMIO+'h204);
      for(int i=0;i<64;i++) expect_word(SRAM+'h1400+32'(i*4),32'((i%2 != 0) ? 0 : i));
    end
    wait_unit(MMIO+'h104,mutate);
    for(int i=0;i<m;i++) for(int j=0;j<n;j++) begin
      expected=0;
      for(int t=0;t<k;t++) expected += av[i*k+t]*bv[t*n+j];
      expect_word(SRAM+'h800+32'((i*n+j)*4),32'(expected));
    end
    if(mutate) begin
      rd(MMIO+'h104,s);
      if(s!==6) $fatal(1,"Busy mutation error not sticky: %h",s);
      expect_word(MMIO+'h114,32'(m));
    end
    mat_jobs++;
  endtask
  task automatic expect_command_error(input logic [31:0] ctrl,status);
    wr(ctrl,1);expect_word(status,4);wr(ctrl,2);expect_word(status,0);
  endtask
  task automatic dma_config(input int channel, input logic [31:0] src,dst,
                            input int row_bytes,rows,ss,ds,mode);
    logic [31:0] base;
    base=MMIO+'h300+32'(channel*256);
    wr(base+8,src);wr(base+12,dst);wr(base+16,32'(row_bytes));wr(base+20,32'(rows));
    wr(base+24,32'(ss));wr(base+28,32'(ds));wr(base+32,32'(mode));wr(base+52,0);
  endtask
  task automatic rx_beat(input logic [31:0] data,input logic [3:0] keep,
                         input bit last,input int gap=0);
    int waited;
    repeat(gap) @(negedge clk);
    @(negedge clk);rx_valid=1;rx_data=data;rx_keep=keep;rx_last=last;
    waited=0;
    do begin @(posedge clk);waited++;if(waited>1000) $fatal(1,"RX stalled");end while(!rx_ready);
    @(negedge clk);rx_valid=0;
  endtask
  task automatic tx_beat(input logic [31:0] expected,input logic [3:0] keep,
                         input bit last,input int stall=0);
    int waited;
    logic [31:0] held_data;
    logic [3:0] held_keep;
    bit held_last;
    logic [31:0] mask;
    @(negedge clk);tx_ready=0;
    waited=0;
    while(!tx_valid) begin @(negedge clk);waited++;if(waited>1000) $fatal(1,"TX stalled");end
    held_data=tx_data;held_keep=tx_keep;held_last=tx_last;
    repeat(stall) begin
      @(negedge clk);
      if(!tx_valid || tx_data!==held_data || tx_keep!==held_keep || tx_last!==held_last)
        $fatal(1,"TX unstable under backpressure");
    end
    mask={{8{keep[3]}},{8{keep[2]}},{8{keep[1]}},{8{keep[0]}}};
    if((tx_data & mask)!==(expected & mask) || tx_keep!==keep || tx_last!==last)
      $fatal(1,"TX mismatch got=%h keep=%h last=%b expected=%h keep=%h last=%b",tx_data,tx_keep,tx_last,expected,keep,last);
    tx_ready=1;@(posedge clk);@(negedge clk);tx_ready=0;checks++;
  endtask
  task automatic wait_dma_fault(input int ch,code);
    logic [31:0] base,v;
    bit stopped;
    base=MMIO+'h300+32'(ch*256);stopped=0;
    for(int t=0;t<100 && !stopped;t++) begin rd(base+4,v);stopped=v[2]&&!v[0];end
    if(!stopped) $fatal(1,"DMA fault timeout channel=%0d status=%h",ch,v);
    expect_word(base+48,32'(code));
  endtask
  task automatic invalid_dma(input int ch);
    logic [31:0] base;
    base=MMIO+'h300+32'(ch*256);
    wr(base,1);expect_word(base+4,4);expect_word(base+48,1);
    wr(base,2);expect_word(base+4,0);
  endtask
  task automatic dma_tests;
    logic [31:0] ignored,data;
    int before_abort;
    // 2D RX/TX/copy: seven bytes per row, gaps and masked tail writes.
    for(int r=0;r<3;r++) for(int w=0;w<8;w++) begin
      wr(SRAM+'h1000+32'(r*16+w*4),32'hdeadbeef);
      wr(SRAM+'h1200+32'(r*32+w*4),32'hcafebabe);
    end
    dma_config(0,0,SRAM+'h1000,7,3,0,16,0);wr(MMIO+'h300,1);
    for(int r=0;r<3;r++) begin
      rx_beat(32'h11223344+32'(r),4'hf,0,2);
      rx_beat(32'ha0667788+32'(r),4'h7,r==2,3);
    end
    wait_unit(MMIO+'h304);expect_word(MMIO+'h328,21);
    for(int r=0;r<3;r++) begin
      expect_word(SRAM+'h1000+32'(r*16),32'h11223344+32'(r));
      expect_word(SRAM+'h1004+32'(r*16),32'hde667788+32'(r));
      expect_word(SRAM+'h1008+32'(r*16),32'hdeadbeef);
    end
    dma_config(1,SRAM+'h1000,0,7,3,16,0,1);wr(MMIO+'h400,1);
    for(int r=0;r<3;r++) begin
      tx_beat(32'h11223344+32'(r),4'hf,0,3);
      tx_beat(32'h00667788+32'(r),4'h7,r==2,4);
    end
    wait_unit(MMIO+'h404);expect_word(MMIO+'h428,21);
    dma_config(2,SRAM+'h1000,SRAM+'h1200,7,3,16,32,2);wr(MMIO+'h500,1);
    wait_unit(MMIO+'h504);expect_word(MMIO+'h528,21);
    for(int r=0;r<3;r++) begin
      expect_word(SRAM+'h1200+32'(r*32),32'h11223344+32'(r));
      expect_word(SRAM+'h1204+32'(r*32),32'hca667788+32'(r));
      expect_word(SRAM+'h1208+32'(r*32),32'hcafebabe);
    end
    // Fill tail byte and source broadcast (source stride zero).
    for(int r=0;r<2;r++) begin wr(SRAM+'h1300+32'(r*16),0);wr(SRAM+'h1304+32'(r*16),32'hffffffff);end
    dma_config(2,0,SRAM+'h1300,5,2,0,16,3);wr(MMIO+'h524,32'h12345678);wr(MMIO+'h500,1);
    wait_unit(MMIO+'h504);
    for(int r=0;r<2;r++) begin
      expect_word(SRAM+'h1300+32'(r*16),32'h12345678);expect_word(SRAM+'h1304+32'(r*16),32'hffffff78);
    end
    wr(SRAM+'h1100,32'h87654321);
    dma_config(2,SRAM+'h1100,SRAM+'h1500,4,4,0,8,2);wr(MMIO+'h500,1);wait_unit(MMIO+'h504);
    for(int r=0;r<4;r++) expect_word(SRAM+'h1500+32'(r*8),32'h87654321);
    dma_config(1,SRAM+'h1100,0,4,3,0,0,1);wr(MMIO+'h400,1);
    for(int r=0;r<3;r++) tx_beat(32'h87654321,4'hf,r==2,2);
    wait_unit(MMIO+'h404);
    // Exact in-place copy is safe, partial overlaps are rejected.
    dma_config(2,SRAM+'h1100,SRAM+'h1100,4,1,4,4,2);wr(MMIO+'h500,1);wait_unit(MMIO+'h504);
    expect_word(SRAM+'h1100,32'h87654321);
    dma_config(2,SRAM+'h1100,SRAM+'h1104,8,1,8,8,2);invalid_dma(2);
    dma_config(0,0,SRAM+'h1000,0,1,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,8193,1,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,4,0,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,4,2049,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1001,4,1,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,4,2,0,2,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,8,2,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1ffc,5,1,0,8,0);invalid_dma(0);
    dma_config(0,0,32'hfffffffc,4,1,0,4,0);invalid_dma(0);
    dma_config(0,0,SRAM+'h1000,4,1,0,4,1);invalid_dma(0);
    dma_config(1,SRAM+'h1ffc,0,8,1,8,0,1);invalid_dma(1);
    dma_config(1,SRAM+'h1000,0,4,1,4,0,0);invalid_dma(1);
    // Malformed ingress frames are consumed and reported, never written.
    wr(SRAM+'h1800,32'hc0ffee00);before_abort=rx_aborts;
    dma_config(0,0,SRAM+'h1800,3,1,0,4,0);wr(MMIO+'h300,1);
    rx_beat(32'hffffffff,4'hf,1);wait_dma_fault(0,3);expect_word(SRAM+'h1800,32'hc0ffee00);
    expect_word(MMIO+'h328,0);
    dma_config(0,0,SRAM+'h1800,8,1,0,8,0);wr(MMIO+'h300,1);
    rx_beat(32'hffffffff,4'hf,1);wait_dma_fault(0,3);
    dma_config(0,0,SRAM+'h1800,4,1,0,4,0);wr(MMIO+'h300,1);
    rx_beat(32'hffffffff,4'hf,0);wait_dma_fault(0,3);
    if(rx_aborts-before_abort!=3) $fatal(1,"Missing RX frame-abort notifications");
    // Busy descriptor protection; the original job still completes.
    dma_config(0,0,SRAM+'h1800,4,1,0,4,0);wr(MMIO+'h300,1);
    transfer(1,MMIO+'h310,8,4'hf,1,ignored);wr(MMIO+'h300,1);
    rx_beat(32'h13579bdf,4'hf,1);wait_unit(MMIO+'h304,1);
    expect_word(MMIO+'h304,6);expect_word(MMIO+'h330,2);expect_word(MMIO+'h310,4);
    expect_word(SRAM+'h1800,32'h13579bdf);
    // Abort and timeout are explicit, with committed-byte accounting.
    dma_config(0,0,SRAM+'h1800,4,1,0,4,0);wr(MMIO+'h300,1);wr(MMIO+'h300,4);
    wait_dma_fault(0,5);expect_word(MMIO+'h328,0);
    dma_config(0,0,SRAM+'h1800,4,1,0,4,0);wr(MMIO+'h334,8);wr(MMIO+'h300,1);
    wait_dma_fault(0,6);expect_word(MMIO+'h328,0);
    dma_config(1,SRAM+'h1800,0,4,1,4,0,1);wr(MMIO+'h400,1);
    repeat(8) @(negedge clk);if(!tx_valid) $fatal(1,"Expected stalled TX word");
    before_abort=tx_aborts;wr(MMIO+'h400,4);wait_dma_fault(1,5);
    if(tx_valid || tx_aborts-before_abort!=1) $fatal(1,"TX abort did not invalidate current frame");
    // Maximum capacity fill proves no wraparound at the last SRAM word.
    dma_config(2,0,SRAM,8192,1,0,8192,3);wr(MMIO+'h524,32'h55667788);wr(MMIO+'h500,1);
    wait_unit(MMIO+'h504);expect_word(MMIO+'h528,8192);
    expect_word(SRAM,32'h55667788);expect_word(SRAM+'h1ffc,32'h55667788);
    // Reset a partially committed RX job; SRAM contents are retained, job is cancelled.
    dma_config(0,0,SRAM+'h1800,8,1,0,8,0);wr(MMIO+'h300,1);
    rx_beat(32'habcdef01,4'hf,0);repeat(4) @(negedge clk);
    rst_n=0;repeat(5) @(negedge clk);rst_n=1;
    expect_word(MMIO+'h304,0);expect_word(MMIO+'h328,0);expect_word(MMIO+8,0);
    expect_word(SRAM+'h1800,32'habcdef01);
    if(rx_ready || tx_valid) $fatal(1,"DMA continued after reset");
    $display("PASS DMA: 2D/strides/broadcast/copy/fill/tail bytes/stream stalls/descriptor errors/abort/timeout/reset");
  endtask
  initial begin : test
    logic [31:0] v,ignored;
    bit finished;
    repeat(5) @(negedge clk);
    rst_n=1;
    $readmemh("boot.hex",boot_image);
    expect_word(MMIO+8,0); // CPU remains in reset while external DMA loads code.
    dma_config(0,0,SRAM,2048,1,0,2048,0);
    wr(MMIO+'h300,1);
    for(int i=0;i<512;i++) rx_beat(boot_image[i],4'hf,i==511,i%3);
    wait_unit(MMIO+'h304);expect_word(MMIO+'h328,2048);
    dma_config(1,SRAM,0,2048,1,2048,0,1);
    wr(MMIO+'h400,1);
    for(int i=0;i<512;i++) tx_beat(boot_image[i],4'hf,i==511,i%4);
    wait_unit(MMIO+'h404);expect_word(MMIO+'h428,2048);
    transfer(1,MMIO+'hc,0,4'hf,1,ignored);
    wr(MMIO+'hc,SRAM+'h80);wr(MMIO+8,1);
    transfer(1,MMIO+'hc,SRAM+'h84,4'hf,1,ignored);
    // The provided CPU must execute the complete firmware through the NMC/MMIO path.
    finished=0;
    for(int t=0;t<20000 && !finished;t++) begin
      rd(MMIO+4,v);finished = v!=0;
    end
    if(!finished || v!==32'h600d0001 || !cpu_done || !cpu_pass) begin

      $fatal(1,"Real CPU firmware self-test failed result=%h",v);
    end
    expect_word(SRAM+'h1400,116);expect_word(SRAM+'h1404,32'(-48));
    expect_word(SRAM+'h1408,32'(-83));expect_word(SRAM+'h140c,308);
    $display("PASS real CV32E40P: SRAM fetch -> matmul -> ReLU -> add -> 2D DMA -> CPU checks");
    // Disable CPU only through reset: fetch_enable is sticky inside CV32E40P.
    @(negedge clk);rst_n=0;cpu_run=0;
    repeat(5) @(negedge clk);rst_n=1;
    expect_word(MMIO,32'h4e505531);
    wr(SRAM+'h1ffc,32'h11223344);
    transfer(1,SRAM+'h1ffc,32'haabbccdd,4'b0101,0,ignored);
    expect_word(SRAM+'h1ffc,32'h11bb33dd);
    transfer(1,SRAM+'h1ffc,32'hffffffff,0,0,ignored);
    expect_word(SRAM+'h1ffc,32'h11bb33dd);
    transfer(0,SRAM+'h2000,0,4'hf,1,ignored);
    transfer(0,SRAM+1,0,4'hf,1,ignored);
    transfer(0,MMIO+'h700,0,4'hf,1,ignored);
    transfer(1,MMIO,0,4'hf,1,ignored);
    transfer(1,MMIO+'h108,SRAM,4'b0001,1,ignored);
    $display("PASS native bus byte masks, alignment, bounds and MMIO decode");
    dma_tests();
    // Deterministic reference calculations cover signed extrema and rectangular shapes.
    mat_test(1,1,1,0);
    mat_test(2,3,4,9);
    mat_test(4,2,5,17);
    mat_test(16,16,16,25,1,1);
    for(int seed=1;seed<=8;seed++) mat_test((seed%4)+1,((seed+1)%4)+1,((seed+2)%7)+1,seed);
    $display("PASS %0d matrix jobs; concurrent matrix/vector/three DMA/host and busy command rejection",mat_jobs);
    // Invalid descriptor coverage: zero/oversize/wraparound/aliasing/alignment.
    mat_config(0,1,1);expect_command_error(MMIO+'h100,MMIO+'h104);
    mat_config(17,1,1);expect_command_error(MMIO+'h100,MMIO+'h104);
    mat_config(1,1,1);wr(MMIO+'h108,SRAM+1);expect_command_error(MMIO+'h100,MMIO+'h104);
    wr(MMIO+'h108,32'hfffffffc);expect_command_error(MMIO+'h100,MMIO+'h104);
    mat_config(2,2,2);wr(MMIO+'h108,SRAM+'h1ffc);expect_command_error(MMIO+'h100,MMIO+'h104);
    mat_config(2,2,2);wr(MMIO+'h110,SRAM);expect_command_error(MMIO+'h100,MMIO+'h104);
    // Vector arithmetic wraps at 32 bits and handles sign-bit extrema.
    wr(SRAM+'h1000,32'h80000000);wr(SRAM+'h1004,32'h7fffffff);
    wr(SRAM+'h1008,32'hffffffff);wr(SRAM+'h100c,0);
    wr(MMIO+'h208,SRAM+'h1000);wr(MMIO+'h20c,SRAM+'h1000);
    wr(MMIO+'h210,4);wr(MMIO+'h214,0);wr(MMIO+'h200,1);
    wait_unit(MMIO+'h204);
    expect_word(SRAM+'h1000,0);expect_word(SRAM+'h1004,32'h7fffffff);
    expect_word(SRAM+'h1008,0);expect_word(SRAM+'h100c,0);
    wr(SRAM+'h1100,1);wr(SRAM+'h1104,1);wr(SRAM+'h1108,32'hffffffff);wr(SRAM+'h110c,2);
    wr(MMIO+'h218,SRAM+'h1100);wr(MMIO+'h214,1);wr(MMIO+'h200,1);
    wait_unit(MMIO+'h204);
    expect_word(SRAM+'h1000,1);expect_word(SRAM+'h1004,32'h80000000);
    expect_word(SRAM+'h1008,32'hffffffff);expect_word(SRAM+'h100c,2);
    wr(MMIO+'h210,0);expect_command_error(MMIO+'h200,MMIO+'h204);
    wr(MMIO+'h210,1025);expect_command_error(MMIO+'h200,MMIO+'h204);
    wr(MMIO+'h210,4);wr(MMIO+'h214,2);expect_command_error(MMIO+'h200,MMIO+'h204);
    wr(MMIO+'h214,0);wr(MMIO+'h20c,SRAM+'h1004);expect_command_error(MMIO+'h200,MMIO+'h204);
    wr(MMIO+'h20c,SRAM+'h1ffc);expect_command_error(MMIO+'h200,MMIO+'h204);
    // Reset in the middle of a long operation cancels bus transactions and sticky state.
    mat_config(16,16,16);wr(MMIO+'h100,1);repeat(8) @(negedge clk);
    rst_n=0;repeat(5) @(negedge clk);rst_n=1;
    expect_word(MMIO+'h104,0);expect_word(MMIO+'h204,0);
    mat_test(1,1,1,31);
    $display("PASS vector signed extrema, wrapping add, in-place, invalid descriptors, reset recovery");
    $display("ALL PASS checks=%0d host_transactions=%0d max_host_wait=%0d cycles",checks,transactions,max_host_wait);
    $finish;
  end
  initial begin
    #10000000;
    $fatal(1,"Global simulation timeout");
  end
endmodule
