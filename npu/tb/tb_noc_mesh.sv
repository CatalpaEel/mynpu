`timescale 1ns/1ps
module tb_noc_mesh #(parameter int ROUTER_DEPTH=2,PACKET_WORDS=16);
 logic clk=0,rst_n=0;always #10 clk=~clk;
 logic [3:0][3:0][1:0] rxv,rxr,rxl,txv,txr,txl;
 logic [3:0][3:0][1:0][31:0] rxd,txd;
 logic [3:0] hreq=0,hwe=0,hgnt,hvalid,herr,ddr_present=4'b1000;
 logic [3:0][3:0] hbe='1;
 logic [3:0][31:0] ha=0,hw=0,hr;
 logic [3:0] dreq,dwe,dgnt,dvalid=0,derror=0;
 logic [3:0][3:0] dbe;
 logic [3:0][31:0] da,dw,dr=0;
 logic [3:0] cpu_done,cpu_pass,noc_irq;
 logic [3:0][4:0] irq;
 logic [3:0][31:0] random_q='{32'h55aa1234,32'hbb123456,32'hacfe8877,32'h732514cc};
 bit stall_links=1,block_reply_to_zero=0;
 logic [3:0] dpending=0;
 int ddelay[4];logic [3:0] dwq;logic [3:0][3:0] dbeq;
 logic [3:0][31:0] daq,dwdataq;
 logic [31:0] ddr_memory[4][16384];
 int checks=0,ack_count=0,ddr_requests=0;longint clocks=0;
 localparam logic [31:0] SRAM=32'h80000000,NOC=32'h40000700,DDR=32'h90000000;
 for(genvar p=0;p<4;p++)begin: nodes
  localparam logic [4:0] MASK=p==0?5'b01011:p==1?5'b01101:p==2?5'b10011:5'b10101;
  npu_noc_soc
`ifndef NOC_GATE_SIM
   #(.ROUTER_DEPTH(ROUTER_DEPTH),.MAX_WORDS(PACKET_WORDS))
`endif
   dut(
   .clk_i(clk),.rst_ni(rst_n),.cpu_run_i(1'b1),
   .node_x_i(4'(p%2)),.node_y_i(4'(p/2)),.port_enable_i(MASK),.mesh_width_i(5'd2),.mesh_height_i(5'd2),.ddr_present_i(ddr_present[p]),
   .link_rx_valid_i(rxv[p]),.link_rx_ready_o(rxr[p]),.link_rx_data_i(rxd[p]),.link_rx_last_i(rxl[p]),
   .link_tx_valid_o(txv[p]),.link_tx_ready_i(txr[p]),.link_tx_data_o(txd[p]),.link_tx_last_o(txl[p]),
   .host_req_i(hreq[p]),.host_we_i(hwe[p]),.host_be_i(hbe[p]),.host_addr_i(ha[p]),.host_wdata_i(hw[p]),
   .host_gnt_o(hgnt[p]),.host_rvalid_o(hvalid[p]),.host_error_o(herr[p]),.host_rdata_o(hr[p]),
   .ddr_req_o(dreq[p]),.ddr_we_o(dwe[p]),.ddr_be_o(dbe[p]),.ddr_addr_o(da[p]),.ddr_wdata_o(dw[p]),
   .ddr_gnt_i(dgnt[p]),.ddr_rvalid_i(dvalid[p]),.ddr_error_i(derror[p]),.ddr_rdata_i(dr[p]),
   .dma_rx_valid_i(1'b0),.dma_rx_ready_o(),.dma_rx_data_i(32'b0),.dma_rx_keep_i(4'hf),.dma_rx_last_i(1'b0),.dma_rx_abort_o(),
   .dma_tx_valid_o(),.dma_tx_ready_i(1'b0),.dma_tx_data_o(),.dma_tx_keep_o(),.dma_tx_last_o(),.dma_tx_abort_o(),
   .irq_o(irq[p]),.noc_irq_o(noc_irq[p]),.cpu_test_done_o(cpu_done[p]),.cpu_test_pass_o(cpu_pass[p])
  );
 end
 always_comb begin
  rxv='0;rxd='0;rxl='0;txr='0;
  for(int p=0;p<4;p++)for(int dir=0;dir<4;dir++)begin
   int q,opposite;
   q=-1;opposite=0;
   case(dir)
    0:begin if(p%2==0)q=p+1;opposite=1;end
    1:begin if(p%2==1)q=p-1;opposite=0;end
    2:begin if(p/2==0)q=p+2;opposite=3;end
    3:begin if(p/2==1)q=p-2;opposite=2;end
   endcase
   if(q>=0)for(int v=0;v<2;v++)begin
    logic enabled;
    enabled=(!stall_links || random_q[p][dir*2+v] || random_q[p][16+dir*2+v]) && !(block_reply_to_zero && q==0 && v==1);
    rxv[q][opposite][v]=txv[p][dir][v] && enabled;
    rxd[q][opposite][v]=txd[p][dir][v];rxl[q][opposite][v]=txl[p][dir][v];
    txr[p][dir][v]=rxr[q][opposite][v] && enabled;
   end
  end
  for(int p=0;p<4;p++)dgnt[p]=ddr_present[p] && !dpending[p] && dreq[p] && random_q[p][5];
 end
 always @(negedge clk)for(int p=0;p<4;p++)random_q[p]<={random_q[p][30:0],random_q[p][31]^random_q[p][21]^random_q[p][1]^random_q[p][0]};
 always @(posedge clk)begin
  clocks++;
  for(int p=0;p<4;p++)begin
   dvalid[p]<=0;
   if(!rst_n)dpending[p]<=0;
   else begin
    if(dgnt[p])begin
     dpending[p]<=1;daq[p]<=da[p];dwq[p]<=dwe[p];dbeq[p]<=dbe[p];dwdataq[p]<=dw[p];ddelay[p]<=int'(random_q[p][10:8])+1;ddr_requests++;
    end
    if(dpending[p])begin
     if(ddelay[p]==0)begin
      dpending[p]<=0;dvalid[p]<=1;derror[p]<=daq[p]==DDR+'hf000;
      dr[p]<=ddr_memory[p][daq[p][15:2]];
      if(dwq[p] && daq[p]!=DDR+'hf000)for(int b=0;b<4;b++)if(dbeq[p][b])ddr_memory[p][daq[p][15:2]][b*8+:8]<=dwdataq[p][b*8+:8];
     end else ddelay[p]<=ddelay[p]-1;
    end
   end
  end
 end
 // Every presented output must remain stable until its own VN accepts it.
 logic [3:0][3:0][1:0] held='0;
 logic [3:0][3:0][1:0][32:0] held_flit;
 always @(posedge clk)begin
  for(int p=0;p<4;p++)for(int d=0;d<4;d++)for(int v=0;v<2;v++)begin
   if(rst_n && held[p][d][v] && (!txv[p][d][v] || {txl[p][d][v],txd[p][d][v]}!==held_flit[p][d][v]))$fatal(1,"Unstable stalled flit p=%0d dir=%0d vn=%0d",p,d,v);
   held[p][d][v]<=rst_n && txv[p][d][v] && !txr[p][d][v];
   held_flit[p][d][v]<={txl[p][d][v],txd[p][d][v]};
  end
 end
 task automatic transfer(input int p,input bit wr,input logic [31:0] a,d,input bit expect_error,output logic [31:0] value);
  int wait_cycles;
  @(negedge clk);hreq[p]=1;hwe[p]=wr;ha[p]=a;hw[p]=d;hbe[p]=15;wait_cycles=0;
  do begin @(posedge clk);wait_cycles++;if(wait_cycles>1000)$fatal(1,"Host starvation node=%0d",p);end while(!hgnt[p]);
  @(negedge clk);hreq[p]=0;wait_cycles=0;
  while(!hvalid[p])begin @(negedge clk);wait_cycles++;if(wait_cycles>1000)$fatal(1,"Host response timeout node=%0d",p);end
  if(herr[p]!==expect_error)$fatal(1,"Host error p=%0d a=%h got=%b",p,a,herr[p]);value=hr[p];
 endtask
 task automatic write_word(input int p,input logic [31:0] a,d);
  logic [31:0] value;transfer(p,1,a,d,0,value);
 endtask
 task automatic read_word(input int p,input logic [31:0] a,output logic [31:0] value);
  transfer(p,0,a,0,0,value);
 endtask
 task automatic expect_word(input int p,input logic [31:0] a,expected);
  logic [31:0] value;read_word(p,a,value);if(value!==expected)$fatal(1,"Data p=%0d a=%h got=%h expected=%h",p,a,value,expected);checks++;
 endtask
 task automatic start(input int p,dest,op,input logic [31:0] remote,local_a,length,input int timeout_cycles=10000);
  write_word(p,NOC+8,32'((op<<8)|((dest/2)<<4)|(dest%2)));write_word(p,NOC+12,remote);write_word(p,NOC+16,length);
  write_word(p,NOC+20,local_a);write_word(p,NOC+24,32'(timeout_cycles));write_word(p,NOC,1);
 endtask
 task automatic finish(input int p,input logic [31:0] expected_bytes,input int error_code=0);
  logic [31:0] value;int limit=0;
  do begin read_word(p,NOC+4,value);limit++;if(limit>100000)$fatal(1,"Network deadlock p=%0d",p);if(value[0])repeat(8)@(negedge clk);end while(value[0]);
  if(error_code==0)begin if(value[2:1]!==2'b01)$fatal(1,"Network command fault p=%0d status=%h",p,value);ack_count++;end
  else begin if(!value[2] || value[1])$fatal(1,"Missing command fault p=%0d status=%h",p,value);expect_word(p,NOC+32,32'(error_code));end
  expect_word(p,NOC+28,expected_bytes);if(!noc_irq[p])$fatal(1,"No completion IRQ p=%0d",p);
 endtask
 task automatic move(input int p,dest,op,input logic [31:0] remote,local_a,length,input int error_code=0);
  start(p,dest,op,remote,local_a,length);finish(p,error_code==0 ? length:0,error_code);
 endtask
 task automatic reset_fabric;
  @(negedge clk);rst_n=0;hreq=0;block_reply_to_zero=0;repeat(5)@(negedge clk);rst_n=1;
 endtask
 logic [7:0] image[8192],golden[10];
 initial begin
  logic [31:0] value,unused,expected;int limit;
  for(int p=0;p<4;p++)for(int i=0;i<16384;i++)ddr_memory[p][i]=0;
  reset_fabric();
  for(int p=0;p<4;p++)begin expect_word(p,NOC+36,32'((p/2)*16+p%2));expect_word(p,NOC+44,32'(PACKET_WORDS));end
  for(int i=0;i<18;i++)begin write_word(0,SRAM+'h1400+32'(i*4),32'h10203040+32'(i));write_word(3,SRAM+'h1500+32'(i*4),32'ha5a5a5a5);write_word(0,SRAM+'h1600+32'(i*4),32'hcccccccc);end
  start(0,3,1,SRAM+'h1500,SRAM+'h1400,67);
  transfer(0,1,NOC+16,4,1,unused); // Busy descriptors cannot change.
  finish(0,67);
  for(int i=0;i<16;i++)expect_word(3,SRAM+'h1500+32'(i*4),32'h10203040+32'(i));
  expect_word(3,SRAM+'h1540,32'ha5203050);expect_word(3,SRAM+'h1544,32'ha5a5a5a5);
  move(0,3,2,SRAM+'h1500,SRAM+'h1600,67);
  for(int i=0;i<16;i++)expect_word(0,SRAM+'h1600+32'(i*4),32'h10203040+32'(i));expect_word(0,SRAM+'h1640,32'hcc203050);
  move(0,0,1,SRAM+'h1700,SRAM+'h1400,64);expect_word(0,SRAM+'h1700,32'h10203040);
  $display("NOC partial-byte, segmented DMA, self-route and busy protection PASS");
  for(int p=0;p<4;p++)for(int i=0;i<64;i++)write_word(p,SRAM+'h1000+32'(i*4),32'h55000000+32'(p*65536+i));
  fork
   move(0,3,1,SRAM+'h1800,SRAM+'h1000,256);
   move(1,2,1,SRAM+'h1800,SRAM+'h1000,256);
   move(2,1,1,SRAM+'h1800,SRAM+'h1000,256);
   move(3,0,1,SRAM+'h1800,SRAM+'h1000,256);
  join
  for(int p=0;p<4;p++)for(int i=0;i<64;i++)expect_word(p,SRAM+'h1800+32'(i*4),32'h55000000+32'((3-p)*65536+i));
  fork
   move(0,1,2,SRAM+'h1000,SRAM+'h1700,64);
   move(1,2,2,SRAM+'h1000,SRAM+'h1700,64);
   move(2,3,2,SRAM+'h1000,SRAM+'h1700,64);
   move(3,0,2,SRAM+'h1000,SRAM+'h1700,64);
  join
  for(int p=0;p<4;p++)for(int i=0;i<16;i++)expect_word(p,SRAM+'h1700+32'(i*4),32'h55000000+32'(((p+1)%4)*65536+i));
  $display("NOC concurrent crossing writes / cyclic remote reads under link backpressure PASS");
  move(0,3,1,DDR+'h1000,SRAM+'h1400,67);move(2,3,2,DDR+'h1000,SRAM+'h1b00,67);
  for(int i=0;i<16;i++)expect_word(2,SRAM+'h1b00+32'(i*4),32'h10203040+32'(i));
  ddr_present[1]=1;move(0,1,1,DDR+'h2000,SRAM+'h1400,16);move(2,1,2,DDR+'h2000,SRAM+'h1c00,16);expect_word(2,SRAM+'h1c00,32'h10203040);
  $display("NOC identical nodes with DDR enabled at either node 1 or 3 PASS");
  move(0,3,1,SRAM+'h2000,SRAM+'h1400,4,3);
  move(0,0,2,DDR,SRAM+'h1400,4,3);
  move(0,3,2,DDR+'hf000,SRAM+'h1d00,4,7);
  move(0,3,1,DDR+'hf000,SRAM+'h1400,4,7);
  start(0,3,1,DDR+'heffc,SRAM+'h1400,8);finish(0,4,7);
  write_word(0,SRAM+'h1d00,32'ha5a5a5a5);write_word(0,SRAM+'h1d04,32'ha5a5a5a5);
  start(0,3,2,DDR+'heffc,SRAM+'h1d00,8);finish(0,4,7);
  expect_word(0,SRAM+'h1d00,32'h10203040);expect_word(0,SRAM+'h1d04,32'ha5a5a5a5);
  $display("NOC partial commit accounting / DDR error trailer PASS");
  start(0,3,1,SRAM,SRAM+'h2000,4);finish(0,0,1);
  start(0,3,1,SRAM,SRAM,0);finish(0,0,1);
  write_word(0,NOC+8,32'h102);write_word(0,NOC+12,SRAM);write_word(0,NOC+16,4);write_word(0,NOC+20,SRAM);write_word(0,NOC,1);finish(0,0,1);
  $display("NOC local bounds, unreachable destination, remote bounds, absent DDR and DDR bus errors PASS");
  $readmemh("noc_boot.hex",image,0,1023);
  for(int i=0;i<1024;i+=4)begin value=0;for(int b=0;b<4;b++)value[b*8+:8]=image[i+b];write_word(0,SRAM+32'(i),value);end
  write_word(0,32'h40000008,1);limit=0;
  while(!cpu_done[0])begin @(negedge clk);limit++;if(limit>10000)$fatal(1,"CPU NoC WFI timeout");end
  if(!cpu_pass[0])$fatal(1,"CPU NoC driver failed");
  for(int i=0;i<4;i++)expect_word(3,SRAM+'h1a00+32'(i*4),32'h10203040+32'(i));
  $display("NOC CPU MMIO configuration / network DMA / WFI IRQ21 PASS");
  block_reply_to_zero=1;start(0,3,1,SRAM+'h1d00,SRAM+'h1400,4,256);finish(0,0,8);read_word(0,NOC+4,value);if(!value[3])$fatal(1,"Timeout did not quarantine");
  transfer(0,1,NOC,2,1,unused);
  move(1,2,2,SRAM+'h1000,SRAM+'h1d00,4);
  $display("NOC timeout quarantine / independent response VN progress PASS");
  block_reply_to_zero=0;repeat(100)@(negedge clk);expect_word(0,NOC+28,0);expect_word(0,NOC+4,12);
  reset_fabric();write_word(0,SRAM+'h1d00,32'hdeadbeef);
  block_reply_to_zero=1;start(0,3,2,SRAM+'h1000,SRAM+'h1d00,4,256);finish(0,0,8);
  block_reply_to_zero=0;repeat(100)@(negedge clk);
  expect_word(0,SRAM+'h1d00,32'hdeadbeef);expect_word(0,NOC+28,0);expect_word(0,NOC+4,12);
  $display("NOC late ACK/read response drained without resurrecting command or writing SRAM PASS");
  reset_fabric();
  // Boot the SAME node through NoC, run unchanged Tiny MNIST, retrieve result.
  $readmemh("sram7.hex",image);for(int i=0;i<8192;i+=4)begin value=0;for(int b=0;b<4;b++)value[b*8+:8]=image[i+b];write_word(0,SRAM+32'(i),value);end
  move(0,3,1,SRAM,SRAM,8192);
  write_word(0,SRAM+'h1e00,1);move(0,3,1,32'h40000008,SRAM+'h1e00,4);
  repeat(200)@(negedge clk);
  move(0,3,2,32'h40000604,SRAM+'h1d40,4);read_word(0,SRAM+'h1d40,value);
  if(!value[0])$fatal(1,"Remote CNN did not overlap NoC traffic");
  move(1,3,1,SRAM+'h1e00,SRAM+'h1000,128);
  for(int i=0;i<32;i++)expect_word(3,SRAM+'h1e00+32'(i*4),32'h55010000+32'(i));
  $display("NOC DMA concurrently shares SRAM with active CNN, disjoint buffers PASS");
  limit=0;while(!cpu_done[3])begin @(negedge clk);limit++;if(limit>100000)$fatal(1,"Remote CNN timeout");end
  if(!cpu_pass[3])$fatal(1,"Remote CNN firmware failed");
  move(0,3,2,SRAM+'h1f00,SRAM+'h1d00,4);expect_word(0,SRAM+'h1d00,7);
  move(0,3,2,SRAM+'h1400,SRAM+'h1d10,10);$readmemh("gold7_5.hex",golden);
  for(int i=0;i<10;i+=4)begin read_word(0,SRAM+'h1d10+32'(i),value);for(int b=0;b<4 && i+b<10;b++)begin if(value[b*8+:8]!==golden[i+b])$fatal(1,"Remote CNN logit mismatch");checks++;end end
  move(0,3,2,32'h40000724,SRAM+'h1d30,4);expect_word(0,SRAM+'h1d30,32'h11);
  $display("NOC boot -> Tiny MNIST -> routed logits/classification PASS");
  $display("NOC MESH PASS identical_nodes=4 topology=2x2 checks=%0d acknowledged_commands=%0d ddr_requests=%0d cycles=%0d",checks,ack_count,ddr_requests,clocks);$finish;
 end
 initial begin #200000000;$fatal(1,"Global mesh timeout");end
endmodule
