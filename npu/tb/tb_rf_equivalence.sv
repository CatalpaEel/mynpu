`timescale 1ns / 1ps
// Functional memory scoreboard, not cycle-equivalence to the historical 1RW
// arbiter. Grants may improve; every granted operation must obey 1R1W limits
// and return pre-write data with the unchanged one-cycle response protocol.
module rf_equivalence_check #(
  parameter int G = 9, M = 7, IW = $clog2(M)
) (output logic done = 0);
  import npu_addr_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [M-1:0] req_i = 0, we_i = 0;
  logic [M-1:0][3:0] be_i = '1;
  logic [M-1:0][31:0] addr_i = 0, wdata_i = 0;
  logic exclude_i = 0;
  logic [IW-1:0] excluded_owner_i = 0;
  logic [G-1:0] gather_req_i = 0;
  logic [G-1:0][31:0] gather_addr_i = 0;
  wire [M-1:0] gnt_o, rvalid_o;
  wire [M-1:0][31:0] rdata_o;
  wire [G-1:0] gather_gnt_o, gather_valid_o, gather_error_o;
  wire [G-1:0][31:0] gather_data_o;
  npu_data_regfile #(.GATHER_PORTS(G), .NUM_MASTERS(M), .ID_W(IW)) dut (.*);
  logic [31:0] memory[2*RF_BANK_WORDS];
  int checks = 0, overlaps = 0, same_word = 0, broadcasts = 0;
  int read_wins = 0, gather_wins = 0, writer_wins = 0;
  function automatic int bank(input logic [31:0] address);
    return int'({address[RF_BANK_BITS+2], address[3:2] ^ address[6:5]});
  endfunction
  function automatic bit valid(input logic [31:0] address);
    return is_rf_address(address) && address[1:0] == 0;
  endfunction
  task automatic cycle_check;
    logic [M-1:0] expected_valid;
    logic [M-1:0][31:0] expected_data;
    logic [G-1:0] expected_gvalid, expected_gerror;
    logic [G-1:0][31:0] expected_gdata;
    int reads[8], writes[8], read_address[8], read_halves[2], write_halves[2];
    #1;
    expected_valid = gnt_o;
    expected_gvalid = gather_gnt_o;
    expected_data = 0;
    expected_gdata = 0;
    expected_gerror = 0;
    for (int b=0;b<8;b++) begin reads[b]=0; writes[b]=0; read_address[b]=-1; end
    for (int h=0;h<2;h++) begin read_halves[h]=0; write_halves[h]=0; end
    if (!rst_ni && (|gnt_o || |gather_gnt_o)) $fatal(1,"Grant during reset");
    // Snapshot all read values BEFORE applying any writes to the scoreboard.
    for (int m=0;m<M;m++) if (gnt_o[m]) begin
      if (!req_i[m] || !valid(addr_i[m]) || (exclude_i && excluded_owner_i==IW'(m)))
        $fatal(1,"Illegal ordinary grant");
      if (we_i[m]) begin
        writes[bank(addr_i[m])]++;
        write_halves[bank(addr_i[m])/4]++;
      end else begin
        read_halves[bank(addr_i[m])/4]++;
        reads[bank(addr_i[m])]++;
        read_address[bank(addr_i[m])] = int'(addr_i[m]);
        expected_data[m] = memory[(addr_i[m]-RF_BASE)/4];
      end
    end
    for (int p=0;p<G;p++) if (gather_gnt_o[p]) begin
      if (!gather_req_i[p]) $fatal(1,"Gather grant without request");
      if (!valid(gather_addr_i[p])) expected_gerror[p]=1;
      else begin
        if (reads[bank(gather_addr_i[p])] && read_address[bank(gather_addr_i[p])] != int'(gather_addr_i[p]))
          $fatal(1,"Two read addresses in one physical bank");
        if (reads[bank(gather_addr_i[p])]) broadcasts++;
        reads[bank(gather_addr_i[p])] = 1;
        read_address[bank(gather_addr_i[p])] = int'(gather_addr_i[p]);
        expected_gdata[p] = memory[(gather_addr_i[p]-RF_BASE)/4];
      end
    end
    for (int h=0;h<2;h++)
      if (read_halves[h]>1 || write_halves[h]>1) $fatal(1,"Logical lane overbooking");
    for (int b=0;b<8;b++) begin
      if (reads[b]>1 || writes[b]>1) $fatal(1,"Physical port overbooking");
      if (reads[b] && writes[b]) overlaps++;
    end
    for (int m=0;m<M;m++) if (gnt_o[m] && we_i[m]) begin
      if (read_address[bank(addr_i[m])]==int'(addr_i[m])) same_word++;
      for (int k=0;k<4;k++) if (be_i[m][k])
        memory[(addr_i[m]-RF_BASE)/4][8*k+:8]=wdata_i[m][8*k+:8];
    end
    @(posedge clk_i);
    #1;
    if (rvalid_o !== expected_valid || rdata_o !== expected_data ||
        gather_valid_o !== expected_gvalid || gather_error_o !== expected_gerror ||
        gather_data_o !== expected_gdata) $fatal(1,"RF 1R1W payload/protocol mismatch G=%0d step=%0d",G,checks);
    checks++;
  endtask
  initial begin
    repeat(4) @(negedge clk_i);
    rst_ni=1;
    for (int word=0;word<2*RF_BANK_WORDS;word++) begin
      @(negedge clk_i);
      req_i=1;we_i=1;addr_i[0]=RF_BASE+32'(word*4);wdata_i[0]=32'(word)^32'h76543210;
      cycle_check();
    end
    // Same half AND same physical bank, first different rows, then same word.
    for (int n=0;n<40;n++) begin
      @(negedge clk_i);
      req_i=3;we_i=1;be_i[0]=4'(n);wdata_i[0]=32'hdeadc000+32'(n);
      addr_i[0]=RF_BASE;addr_i[1]=RF_BASE+32'((n%2)*16);
      #1;
      if (gnt_o[1:0]!=3) $fatal(1,"1R1W ordinary R/W not accepted together");
      cycle_check();
    end
    // Writes must coexist with same-bank gather, including same-word broadcast.
    for (int n=0;n<40;n++) begin
      @(negedge clk_i);
      req_i=1;we_i=1;be_i[0]=4'(n);wdata_i[0]=32'hbaad1000+32'(n);addr_i[0]=RF_BASE;
      gather_req_i='1;
      for (int p=0;p<G;p++) gather_addr_i[p]=RF_BASE;
      #1;
      if (!gnt_o[0] || !(&gather_gnt_o)) $fatal(1,"Writer blocks same-bank gather");
      cycle_check();
    end
    // Continuous three-way contention: both read classes get service, writes
    // continue every cycle. No consumer may be starved by the writer.
    for (int n=0;n<80;n++) begin
      @(negedge clk_i);
      req_i=3;we_i=1;addr_i[1]=RF_BASE;gather_req_i=1;
      #1;
      if (!gnt_o[0]) $fatal(1,"Read contention blocks independent writer");
      read_wins+=int'(gnt_o[1]);gather_wins+=int'(gather_gnt_o[0]);writer_wins++;
      cycle_check();
    end
    if (read_wins<30 || gather_wins<30) $fatal(1,"RF read arbiter starvation");
    for (int n=0;n<5000;n++) begin
      @(negedge clk_i);
      rst_ni=n%997!=0;
      exclude_i=$urandom_range(0,3)==0;excluded_owner_i=IW'($urandom_range(0,M-1));
      for (int m=0;m<M;m++) begin
        req_i[m]=$urandom_range(0,3)!=0;we_i[m]=1'($urandom);be_i[m]=4'($urandom);wdata_i[m]=$urandom;
        addr_i[m]=RF_BASE+32'($urandom_range(0,2*RF_BANK_WORDS-1)*4);
        if (n%13==0) addr_i[m]+=1;
        if (n%17==0) addr_i[m]=32'h80000000;
      end
      for (int p=0;p<G;p++) begin
        gather_req_i[p]=$urandom_range(0,3)!=0;
        gather_addr_i[p]=RF_BASE+32'($urandom_range(0,2*RF_BANK_WORDS-1)*4);
        if (n%19==0) gather_addr_i[p]+=1;
        if (n%23==0) gather_addr_i[p]=32'h80000000;
        if (n%257<20) begin gather_req_i[p]=1;gather_addr_i[p]=RF_BASE;end
      end
      cycle_check();
    end
    if (!overlaps || !same_word || !broadcasts) $fatal(1,"Missing concurrent coverage");
    $display("RF 1R1W G=%0d M=%0d checks=%0d overlaps=%0d old_word=%0d broadcasts=%0d fair_read=%0d fair_gather=%0d writes=%0d",G,M,checks,overlaps,same_word,broadcasts,read_wins,gather_wins,writer_wins);
    done=1;
  end
endmodule
// Sustained same-bank writer + gather reader, both with 256 useful words.
// The frozen 1RW reference and new RF see independent handshake-driven sources.
module rf_rw_bandwidth #(parameter bit OLD = 0)(output logic done=0);
  import npu_addr_pkg::*;
  logic clk_i=0,rst_ni=0;
  always #10 clk_i=~clk_i;
  logic [3:0] req_i=0,we_i=1;
  logic [3:0][3:0] be_i='1;
  logic [3:0][31:0] addr_i=0,wdata_i=0;
  logic exclude_i=0;
  logic [1:0] excluded_owner_i=0;
  logic [2:0] gather_req_i=0;
  logic [2:0][31:0] gather_addr_i=0;
  wire [3:0] gnt_o,rvalid_o;
  wire [3:0][31:0] rdata_o;
  wire [2:0] gather_gnt_o,gather_valid_o,gather_error_o;
  wire [2:0][31:0] gather_data_o;
  generate if(OLD) begin : g_old
    npu_data_regfile_reference #(.GATHER_PORTS(3),.NUM_MASTERS(4),.ID_W(2)) dut(.*);
  end else begin : g_new
    npu_data_regfile #(.GATHER_PORTS(3),.NUM_MASTERS(4),.ID_W(2)) dut(.*);
  end endgenerate
  int writes=0,reads=0,cycles=0;
  logic [31:0] model=32'h12345678,expected;
  logic wg,rg;
  initial begin
    repeat(4) @(negedge clk_i);
    rst_ni=1;addr_i[0]=RF_BASE;gather_addr_i[0]=RF_BASE;
    req_i=1;wdata_i[0]=model;
    @(negedge clk_i);req_i=0;
    while(writes<256 || reads<256) begin
      @(negedge clk_i);
      req_i[0]=writes<256;gather_req_i[0]=reads<256;wdata_i[0]=32'hfedc0000+32'(writes);
      #1;wg=gnt_o[0];rg=gather_gnt_o[0];expected=model;
      if(wg) begin model=wdata_i[0];writes++;end
      if(rg) reads++;
      @(posedge clk_i);#1;
      if(rvalid_o[0]!==wg || gather_valid_o[0]!==rg || (rg && gather_data_o[0]!==expected))
        $fatal(1,"Bandwidth test memory/response mismatch");
      cycles++;
      if(cycles>520) $fatal(1,"Bandwidth test stalled");
    end
    if(cycles != (OLD ? 512:256)) $fatal(1,"Unexpected sustained RF throughput");
    $display("RF RW BANDWIDTH old=%0d writes=%0d reads=%0d cycles=%0d",OLD,writes,reads,cycles);
    done=1;
  end
endmodule
module tb_rf_equivalence;
  wire [3:0] done;
  rf_equivalence_check #(.G(3),.M(4)) a(.done(done[0]));
  rf_equivalence_check #(.G(9),.M(7)) b(.done(done[1]));
  rf_rw_bandwidth #(.OLD(1)) old_bw(.done(done[2]));
  rf_rw_bandwidth #(.OLD(0)) new_bw(.done(done[3]));
  initial begin
    wait(&done);
    $display("RF EQUIVALENCE PASS 1R1W functional scoreboard and sustained R/W benchmark");
    $finish;
  end
  initial begin #2000000;$fatal(1,"RF test timeout");end
endmodule
