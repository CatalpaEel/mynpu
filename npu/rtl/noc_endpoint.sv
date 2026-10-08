// Native-memory network DMA. One outstanding local command, independently
// serviced incoming requests, separate request/response virtual networks.
// Header: op[31:28], dy[27:24], dx[23:20], sy[19:16], sx[15:12], tid[11:4].
// Request: header, address, {reserved[31:16], words[15:4], final_be[3:0]}, payload.
// Reply: header, optional read payload, {error[31:24], reserved[23:16], bytes[15:0]}.
module noc_endpoint #(
 parameter int MAX_WORDS=16,
 parameter logic [31:0] SRAM_BASE=32'h80000000,
 parameter int SRAM_BYTES=8192,
 parameter logic [31:0] DDR_BASE=32'h90000000,
 parameter int DDR_BYTES=65536
)(
 input logic clk_i,rst_ni,
 input logic [3:0] node_x_i,node_y_i,
 input logic [4:0] port_enable_i,mesh_width_i,mesh_height_i,
 input logic ddr_present_i,
 input logic csr_req_i,csr_we_i,input logic [7:0] csr_addr_i,
 input logic [31:0] csr_wdata_i,output logic [31:0] csr_rdata_o,
 output logic csr_error_o,irq_o,
 output logic [1:0] tx_valid_o,input logic [1:0] tx_ready_i,
 output logic [1:0][31:0] tx_data_o,output logic [1:0] tx_last_o,
 input logic [1:0] rx_valid_i,output logic [1:0] rx_ready_o,
 input logic [1:0][31:0] rx_data_i,input logic [1:0] rx_last_i,
 output logic host_req_o,host_we_o,output logic [3:0] host_be_o,
 output logic [31:0] host_addr_o,host_wdata_o,
 input logic host_gnt_i,host_rvalid_i,host_error_i,input logic [31:0] host_rdata_i,
 output logic ddr_req_o,ddr_we_o,output logic [3:0] ddr_be_o,
 output logic [31:0] ddr_addr_o,ddr_wdata_o,
 input logic ddr_gnt_i,ddr_rvalid_i,ddr_error_i,input logic [31:0] ddr_rdata_i
);
 typedef enum logic [2:0] {CI,CH,CA,CM,CF,CD,CW} client_t;
 typedef enum logic [1:0] {RH,RD,RW} reply_t;
 typedef enum logic [3:0] {SH,SA,SM,SD,SB,SO,SR,SF,ST} server_t;
 client_t cstate;reply_t rstate;server_t sstate;
 logic [31:0] cfg[5]; // destination+operation, remote address, length, local address, watchdog.
 logic done,fault,quarantine;logic [7:0] fault_code;
 logic [3:0] cx,cy,cop;logic [7:0] tid;
 logic [31:0] local_addr,remote_addr,remaining,cbuf,timer,bytes_done;
 logic [11:0] cwords,csent,rcount;
 logic [15:0] chunk_bytes,rbytes;
 logic [3:0] last_be;
 logic rmatch;logic [7:0] rerror;
 logic [3:0] sop,sx,sy;logic [7:0] stid,serror;
 logic [31:0] saddr,sbuf;logic [11:0] swords,sindex;
 logic [3:0] sbe;logic [15:0] sbytes;logic slast;
 logic hpending,hserver,hddr,rr;
 logic creq,sreq,selected_server,selected_ddr,accept,hcomplete;
 logic [31:0] selected_addr,selected_data,hdata;
 logic selected_we,herror;logic [3:0] selected_be;
 logic client_complete,server_complete,progress;
 function automatic logic [31:0] header(input logic [3:0] op,dx,dy,input logic [7:0] id);
  return {op,dy,dx,node_y_i,node_x_i,id,4'b0};
 endfunction
 function automatic logic [2:0] nbytes(input logic [3:0] be);
  return {2'b0,be[0]}+{2'b0,be[1]}+{2'b0,be[2]}+{2'b0,be[3]};
 endfunction
 function automatic logic range_ok(input logic [31:0] a,n,base,input int size);
  return a[1:0]==0 && n!=0 && {1'b0,a}>={1'b0,base} && {1'b0,a}+{1'b0,n}<={1'b0,base}+33'(size);
 endfunction
 function automatic logic reachable(input logic [3:0] x,y);
  if(x>=mesh_width_i || y>=mesh_height_i || !port_enable_i[0])return 0;
  if(x>node_x_i)return port_enable_i[1];
  if(x<node_x_i)return port_enable_i[2];
  if(y>node_y_i)return port_enable_i[3];
  if(y<node_y_i)return port_enable_i[4];
  return 1;
 endfunction
 always_comb begin
  chunk_bytes=remaining>MAX_WORDS*4 ? 16'(MAX_WORDS*4) : remaining[15:0];
  cwords=12'((int'(chunk_bytes)+3)/4);
  last_be=chunk_bytes[1:0]==0 ? 4'hf : (4'hf>>(4-chunk_bytes[1:0]));
  csr_rdata_o=0;
  case(csr_addr_i)
   8'h04:csr_rdata_o={28'b0,quarantine,fault,done,cstate!=CI};
   8'h08:csr_rdata_o=cfg[0];8'h0c:csr_rdata_o=cfg[1];8'h10:csr_rdata_o=cfg[2];
   8'h14:csr_rdata_o=cfg[3];8'h18:csr_rdata_o=cfg[4];
   8'h1c:csr_rdata_o=bytes_done;8'h20:csr_rdata_o={24'b0,fault_code};
   8'h24:csr_rdata_o={24'b0,node_y_i,node_x_i};
   8'h28:csr_rdata_o={26'b0,ddr_present_i,port_enable_i};
   8'h2c:csr_rdata_o=MAX_WORDS;
   default:;
  endcase
  csr_error_o=csr_addr_i[1:0]!=0 || csr_addr_i>8'h2c ||
    (csr_we_i && (csr_addr_i==4 || csr_addr_i>=8'h1c || cstate!=CI || quarantine));
  irq_o=done || fault;
  tx_valid_o='0;tx_data_o='0;tx_last_o='0;rx_ready_o='0;
  case(cstate)
   CH:begin tx_valid_o[0]=1;tx_data_o[0]=header(cop,cx,cy,tid);end
   CA:begin tx_valid_o[0]=1;tx_data_o[0]=remote_addr;end
   CM:begin tx_valid_o[0]=1;tx_data_o[0]={16'b0,cwords,last_be};tx_last_o[0]=cop==2;end
   CD:begin tx_valid_o[0]=1;tx_data_o[0]=cbuf;tx_last_o[0]=csent+1==cwords;end
   default:;
  endcase
  case(sstate)
   SH,SA,SM,SD:rx_ready_o[0]=1;
   SO:begin tx_valid_o[1]=1;tx_data_o[1]=header(sop==2 ? 4'ha : 4'h9,sx,sy,stid);end
   SF:begin tx_valid_o[1]=1;tx_data_o[1]=sbuf;end
   ST:begin tx_valid_o[1]=1;tx_data_o[1]={serror,8'b0,sbytes};tx_last_o[1]=1;end
   default:;
  endcase
  rx_ready_o[1]=rstate!=RW;
  creq=(cstate==CF) || (rstate==RW && rmatch && rerror==0);
  sreq=(sstate==SB || sstate==SR) && serror==0;
  selected_server=sreq && (!creq || rr);
  selected_addr=selected_server ? saddr+({20'b0,sindex}-(sstate==SB ? 32'd1:32'd0))*4 :
    local_addr+(rstate==RW ? ({20'b0,rcount}-1)*4 : {20'b0,csent}*4);
  selected_we=selected_server ? sstate==SB : rstate==RW;
  selected_data=selected_server ? sbuf : cbuf;
  selected_be=selected_server ? (sstate==SB && sindex==swords ? sbe:4'hf) : (rstate==RW && rcount==cwords ? last_be:4'hf);
  selected_ddr=selected_server && selected_addr>=DDR_BASE && selected_addr<DDR_BASE+DDR_BYTES;
  host_req_o=!hpending && (creq || sreq) && !selected_ddr && rst_ni;
  host_we_o=selected_we;host_addr_o=selected_addr;host_wdata_o=selected_data;host_be_o=selected_be;
  ddr_req_o=!hpending && (creq || sreq) && selected_ddr && rst_ni;
  ddr_we_o=selected_we;ddr_addr_o=selected_addr;ddr_wdata_o=selected_data;ddr_be_o=selected_be;
  accept=(host_req_o && host_gnt_i) || (ddr_req_o && ddr_gnt_i);
  hcomplete=hpending && (hddr ? ddr_rvalid_i : host_rvalid_i);
  hdata=hddr ? ddr_rdata_i:host_rdata_i;herror=hddr ? ddr_error_i:host_error_i;
  client_complete=hcomplete && !hserver;server_complete=hcomplete && hserver;
  progress=(tx_valid_o[0] && tx_ready_i[0]) || (rx_valid_i[1] && rx_ready_o[1] && rmatch) || client_complete;
 end
 always_ff @(posedge clk_i or negedge rst_ni)begin
  if(!rst_ni)begin
   cstate<=CI;rstate<=RH;sstate<=SH;done<=0;fault<=0;quarantine<=0;fault_code<=0;
   cfg[0]<=0;cfg[1]<=0;cfg[2]<=0;cfg[3]<=0;cfg[4]<=4096;
   cx<=0;cy<=0;cop<=0;tid<=0;local_addr<=0;remote_addr<=0;remaining<=0;cbuf<=0;timer<=0;bytes_done<=0;csent<=0;
   rcount<=0;rbytes<=0;rmatch<=0;rerror<=0;sop<=0;sx<=0;sy<=0;stid<=0;serror<=0;saddr<=0;sbuf<=0;swords<=0;sindex<=0;sbe<=0;sbytes<=0;slast<=0;
   hpending<=0;hserver<=0;hddr<=0;rr<=0;
  end else begin
   if(accept)begin hpending<=1;hserver<=selected_server;hddr<=selected_ddr;end
   if(hcomplete)begin hpending<=0;rr<=!hserver;end
   if(cstate!=CI)begin
    timer<=progress ? 0:timer+1;
    if(cfg[4]!=0 && timer>=cfg[4]-1 && !progress)begin
     cstate<=CI;done<=0;fault<=1;fault_code<=8;quarantine<=1;rmatch<=0;
    end
   end
   if(csr_req_i && csr_we_i && !csr_error_o)begin
    if(csr_addr_i>=8 && csr_addr_i<=8'h18)cfg[(csr_addr_i-8)>>2]<=csr_wdata_i;
    if(csr_addr_i==0)begin
     if(csr_wdata_i[1])begin done<=0;fault<=0;fault_code<=0;end
     if(csr_wdata_i[0])begin
      bytes_done<=0;done<=0;fault<=0;fault_code<=0;timer<=0;csent<=0;tid<=tid+1;
      if((cfg[0][11:8]!=1 && cfg[0][11:8]!=2) || cfg[0][31:12]!=0 || !reachable(cfg[0][3:0],cfg[0][7:4]) ||
        !range_ok(cfg[3],cfg[2],SRAM_BASE,SRAM_BYTES) || cfg[1][1:0]!=0 || {1'b0,cfg[1]}+{1'b0,cfg[2]}>33'h100000000)begin fault<=1;fault_code<=1;end
      else begin
       cop<=cfg[0][11:8];cx<=cfg[0][3:0];cy<=cfg[0][7:4];remote_addr<=cfg[1];remaining<=cfg[2];local_addr<=cfg[3];cstate<=CH;
      end
     end
    end
   end
   if(tx_valid_o[0] && tx_ready_i[0])case(cstate)
    CH:cstate<=CA;CA:cstate<=CM;CM:cstate<=cop==2 ? CW:CF;
    CD:if(csent+1==cwords)cstate<=CW;else begin csent<=csent+1;cstate<=CF;end
    default:;
   endcase
   if(client_complete && cstate==CF)begin
    if(herror)begin cstate<=CI;fault<=1;fault_code<=7;quarantine<=1;end
    else begin cbuf<=hdata;cstate<=CD;end
   end
   // Response ingress runs independently of request serving; unsolicited/late
   // replies are drained without writes. Timeout quarantines until fabric reset.
   if(rx_valid_i[1] && rx_ready_o[1])begin
    if(rstate==RH)begin
     rcount<=0;rbytes<=0;rerror<=0;
     rmatch<=cstate==CW && rx_data_i[1][11:4]==tid && rx_data_i[1][15:12]==cx && rx_data_i[1][19:16]==cy;
     if(rx_last_i[1])begin
      rmatch<=0;
      if(cstate==CW && rx_data_i[1][11:4]==tid)begin cstate<=CI;fault<=1;fault_code<=4;end
     end else begin
      rstate<=RD;
      if(rx_data_i[1][31:28]!=(cop==2 ? 4'ha:4'h9))rerror<=4;
     end
    end else if(rx_last_i[1])begin
     rstate<=RH;rmatch<=0;
     if(rmatch && cstate==CW)begin
      if(rerror!=0 || rx_data_i[1][31:24]!=0 || rx_data_i[1][15:0]!=chunk_bytes || (cop==2 && (rcount!=cwords || rbytes!=chunk_bytes)))begin
       fault<=1;fault_code<=rerror!=0 ? rerror : rx_data_i[1][31:24]!=0 ? rx_data_i[1][31:24]:8'd4;cstate<=CI;
       bytes_done<=bytes_done+(cop==2 ? {16'b0,rbytes}:{16'b0,rx_data_i[1][15:0]});
      end else begin
       bytes_done<=bytes_done+{16'b0,chunk_bytes};
       if(remaining=={16'b0,chunk_bytes})begin cstate<=CI;done<=1;end
       else begin remaining<=remaining-{16'b0,chunk_bytes};local_addr<=local_addr+{16'b0,chunk_bytes};remote_addr<=remote_addr+{16'b0,chunk_bytes};csent<=0;tid<=tid+1;cstate<=CH;end
      end
     end
    end else if(rmatch && cstate==CW)begin
     if(cop!=2 || rcount>=cwords)rerror<=4;
     else begin rcount<=rcount+1;if(rerror==0)begin cbuf<=rx_data_i[1];rstate<=RW;end end
    end
   end
   if(rstate==RW && (!rmatch || rerror!=0))rstate<=RD;
   if(client_complete && rstate==RW)begin
    rstate<=RD;
    if(herror)rerror<=7;else rbytes<=rbytes+{13'b0,nbytes(rcount==cwords ? last_be:4'hf)};
   end
   // Independent remote request server, including remote MMIO for boot/control.
   if(rx_valid_i[0] && rx_ready_o[0])case(sstate)
    SH:begin
     sop<=rx_data_i[0][31:28];sx<=rx_data_i[0][15:12];sy<=rx_data_i[0][19:16];stid<=rx_data_i[0][11:4];
     serror<=(rx_data_i[0][31:28]!=1 && rx_data_i[0][31:28]!=2) || rx_data_i[0][23:20]!=node_x_i || rx_data_i[0][27:24]!=node_y_i ? 8'd4:8'd0;
     sbytes<=0;sindex<=0;swords<=0;sstate<=rx_last_i[0] ? SO:SA;
     if(rx_last_i[0])serror<=4;
    end
    SA:begin saddr<=rx_data_i[0];sstate<=rx_last_i[0] ? SO:SM;if(rx_last_i[0])serror<=4;end
    SM:begin
     logic [31:0] length;
     length=({20'b0,rx_data_i[0][15:4]}-1)*4+{29'b0,nbytes(rx_data_i[0][3:0])};
     swords<=rx_data_i[0][15:4];sbe<=rx_data_i[0][3:0];sindex<=0;
     if(rx_data_i[0][31:16]!=0 || rx_data_i[0][15:4]==0 || rx_data_i[0][15:4]>MAX_WORDS ||
       !(rx_data_i[0][3:0]==1 || rx_data_i[0][3:0]==3 || rx_data_i[0][3:0]==7 || rx_data_i[0][3:0]==15))serror<=4;
     else if(!range_ok(saddr,length,SRAM_BASE,SRAM_BYTES) &&
       !(ddr_present_i && range_ok(saddr,length,DDR_BASE,DDR_BYTES)) &&
       !(saddr[31:12]==20'h40000 && saddr[1:0]==0 && rx_data_i[0][15:4]==1 && rx_data_i[0][3:0]==15))serror<=3;
     if(sop==2)begin sstate<=SO;if(!rx_last_i[0])begin serror<=4;sstate<=SD;end end
     else begin sstate<=rx_last_i[0] ? SO:SD;if(rx_last_i[0])serror<=4;end
    end
    SD:begin
     sindex<=sindex+1;slast<=rx_last_i[0];sbuf<=rx_data_i[0];
     if(serror!=0 || sindex>=swords || rx_last_i[0]!=(sindex+1==swords))begin
      if(serror==0)serror<=4;
      if(rx_last_i[0])sstate<=SO;
     end else sstate<=SB;
    end
    default:;
   endcase
   if(server_complete && sstate==SB)begin
    if(herror)serror<=7;else sbytes<=sbytes+{13'b0,nbytes(sindex==swords ? sbe:4'hf)};
    sstate<=slast ? SO:SD;
   end
   if(tx_valid_o[1] && tx_ready_i[1])case(sstate)
    SO:sstate<=sop==2 && serror==0 ? SR:ST;
    SF:begin
     sbytes<=sbytes+{13'b0,nbytes(sindex+1==swords ? sbe:4'hf)};
     if(sindex+1==swords)sstate<=ST;else begin sindex<=sindex+1;sstate<=SR;end
    end
    ST:sstate<=SH;
    default:;
   endcase
   if(server_complete && sstate==SR)begin
    if(herror)begin serror<=7;sstate<=ST;end else begin sbuf<=hdata;sstate<=SF;end
   end
  end
 end
 initial if(MAX_WORDS<1 || MAX_WORDS>2048)$fatal(1,"Invalid NoC packet size");
endmodule
