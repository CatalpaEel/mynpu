`timescale 1ns/1ps
// Saturate all eight ports to verify fairness and response ownership each clock.
module tb_nmc;
  logic clk=0, rst_n=0;
  always #10 clk=~clk;
  logic [7:0] req='0, we='0, gnt, valid, error;
  logic [7:0][3:0] be='1;
  logic [7:0][31:0] addr,wdata='0,rdata;
  logic memreq, mmreq, mmwe;
  logic [3:0] memwen;
  logic [10:0] memaddr;
  logic [11:0] mmaddr;
  logic [31:0] memwdata,memrdata,mmwdata;
  int grant_counts[8]='{default:0};
  nmc dut (
    .clk_i(clk),.rst_ni(rst_n),.req_i(req),.we_i(we),.be_i(be),
    .addr_i(addr),.wdata_i(wdata),.gnt_o(gnt),.rvalid_o(valid),.error_o(error),.rdata_o(rdata),
    .mem_req_o(memreq),.mem_wen_o(memwen),.mem_addr_o(memaddr),.mem_wdata_o(memwdata),
    .mem_rdata_i(memrdata),.mmio_req_o(mmreq),.mmio_we_o(mmwe),.mmio_addr_o(mmaddr),
    .mmio_wdata_o(mmwdata),.mmio_rdata_i(32'h12345678),.mmio_error_i(1'b0)
  );
  always @(posedge clk) if(memreq) memrdata<=32'hface0000 | {21'b0,memaddr};
  initial begin
    int owner;
    logic [7:0] accepted;
    for(int i=0;i<8;i++) addr[i]=32'h80000000+32'(i*4);
    repeat(5) @(negedge clk);rst_n=1;req=8'hff;
    for(int cycle=0;cycle<128;cycle++) begin
      @(posedge clk);accepted=gnt;owner=cycle%8;
      if(accepted !== (8'b00000001<<owner)) $fatal(1,"RR fairness failed cycle=%0d gnt=%b",cycle,gnt);
      #1;
      if(valid!==accepted || error!==0) $fatal(1,"Pipelined response owner mismatch");
      if(rdata[owner] !== (32'hface0000 | 32'(owner))) $fatal(1,"Read data crossed masters");
      grant_counts[owner]++;
    end
    @(negedge clk);req=0;
    @(posedge clk);#1;if(valid!==0) $fatal(1,"Unexpected response without request");
    for(int i=0;i<8;i++) if(grant_counts[i]!=16) $fatal(1,"Unfair counts");
    $display("PASS NMC: 128 consecutive grants/responses, all eight masters receive 16 grants");
    // Hold a competing SRAM request while a registered MMIO write executes.
    // Upstream payload changes must not alter the accepted MMIO command.
    @(negedge clk);req=8'h08;we[3]=1;addr[3]=32'h40000608;wdata[3]=32'h89abcdef;
    @(posedge clk);#1;
    if(valid!==0 || !mmreq || !mmwe || mmaddr!==12'h608 || mmwdata!==32'h89abcdef)
      $fatal(1,"MMIO request stage/payload mismatch");
    @(negedge clk);req=8'h20;we[3]=0;addr[3]=0;wdata[3]=0;
    #1;if(gnt!==0 || mmaddr!==12'h608 || mmwdata!==32'h89abcdef)
      $fatal(1,"MMIO issue slot or captured payload changed");
    @(posedge clk);#1;
    if(valid!==8'h08 || error!==0 || rdata[3]!==32'h12345678 || mmreq)
      $fatal(1,"MMIO response owner/data mismatch");
    @(posedge clk);#1;
    if(valid!==8'h20 || error!==0 || rdata[5]!==32'hface0005)
      $fatal(1,"SRAM response after MMIO crossed masters");
    @(negedge clk);req=0;
    $display("PASS NMC MMIO: registered payload, two-cycle response, SRAM owner preserved");
    $finish;
  end
endmodule
