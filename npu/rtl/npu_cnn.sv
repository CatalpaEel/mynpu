// 4-output tiles, one pipelined MAC, 112 B of explicit flip-flop cache data.
// Activation ping-pong: 2x32 B; weight ping-pong: 2x12 B;
// At most 144 products, each <= 32640 in magnitude: 24 bits are exact.
// four lossless signed 24-bit partial sums: 12 B; packed output queue/assembly: 12 B.
// All code, full tensors and model parameters remain in the sole 8KB SRAM.
module npu_cnn(
 input logic clk_i,rst_ni,csr_req_i,csr_we_i,blocked_i,
 input logic [7:0] csr_addr_i,input logic [31:0] csr_wdata_i,
 output logic [31:0] csr_rdata_o,output logic csr_error_o,
 output logic busy_o,done_o,irq_o,
 output logic req_o,we_o,output logic [3:0] be_o,
 output logic [31:0] addr_o,wdata_o,
 input logic gnt_i,rvalid_i,error_i,input logic [31:0] rdata_i
);
 typedef enum logic [2:0] {IDLE,START,WAIT_TILE,RUN,DRAIN} state_t;
 typedef enum logic [2:0] {BIDLE,WREQ,MREQ,BREQ,PREP,AREQ,COMPLETE} load_t;
 state_t state;load_t load_state;
 logic [31:0] cfg[14];
 (* ram_style="registers" *) logic [7:0] act[2][32];
 (* ram_style="registers" *) logic signed [7:0] weights[2][12];
 logic signed [23:0] sums[4];
 logic signed [31:0] mult[2],bias[2];
 logic [1:0] ready;
 logic bank,load_bank,fault;
 // Metadata belongs to the corresponding ping-pong bank.
 logic [4:0] boc[2],bic[2];logic [5:0] boy[2],box[2];logic [7:0] bfeature[2];
 logic [4:0] oc,ic,noc,nic;
 logic [5:0] oy,ox,noy,nox;
 logic [7:0] feature,nfeature;
 logic next_exists,need_quant,command_valid;
 logic [2:0] cols,ncols;
 logic [3:0] chunk_len,load_len;
 logic [1:0] ky,kx,lane,ky_first,ky_last,kx_first,kx_last;
 logic [6:0] center_y,center_x;
 logic [3:0] ftap;
 logic last_chunk,last_tap;
 logic [12:0] output_base,plane;
 logic [13:0] weight_start,weight_addr,weight_end;
 logic [1:0] load_row;
 logic [13:0] act_addr,clip_start,clip_end,row_logical_start;
 logic signed [8:0] row_y,x_first,x_end;
 logic [13:0] row_base;
 logic [3:0] span;
 logic [31:0] cycles,mac_cycles,issue_cycles,memory_transactions,wait_cycles;
 logic [31:0] input_bytes,weight_bytes,output_bytes;
 logic valid_cfg;
 // Every accepted request carries response metadata; reads may issue each cycle.
 logic pending, pending_write;
 load_t pending_type;
 logic pending_bank;
 logic [13:0] pending_addr,pending_weight_start,pending_clip_start,pending_clip_end,pending_logical;
 logic [1:0] pending_row;
 logic [3:0] pending_len,pending_span;
 // MAC operand stage, followed by four independent accumulation contexts.
 logic tap_valid,tap_final,tap_inside;
 logic [1:0] tap_lane;
 logic signed [8:0] tap_a;
 logic signed [7:0] tap_w;
 logic signed [31:0] tap_m,tap_b;
 logic signed [16:0] term_product;
 logic signed [23:0] dot_sum;
 logic [12:0] tap_tag;
 logic q0valid,q1valid,q2valid;
 logic signed [23:0] q0acc;
 logic signed [31:0] q0m,q0b,q1b;
 logic signed [55:0] q1product,q2scaled;
 logic [12:0] q0tag,q1tag,q2tag;
 logic [7:0] qbyte;
 // Two complete packed words and a partial assembly word. Writes take priority.
 logic [31:0] out_data[2],pack_data;
 logic [3:0] out_be[2],pack_be;
 logic [12:0] out_offset[2];
 logic head,tail;
 logic [1:0] out_count;
 logic push_word,pop_word,write_selected;
 logic [31:0] assembled;
 logic [3:0] assembled_be;
 logic [4:0] activation_index;
 logic inside_image;
 function automatic logic range_ok(input logic [31:0] base,bytes);
  return base[31:13]==19'h40000 && base[1:0]==0 && bytes>0 && bytes<=8192 && {19'b0,base[12:0]}+bytes<=8192;
 endfunction
 function automatic logic overlap(input logic [31:0] a,na,b,nb);
  return {1'b0,a}<({1'b0,b}+nb) && {1'b0,b}<({1'b0,a}+na);
 endfunction
 function automatic logic [7:0] requant(input logic signed [55:0] value,input logic [7:0] zp,input logic relu);
  logic signed [31:0] quotient;
  quotient=$signed(value[55:24]);
  if(value[23:0]>24'h800000 || (value[23:0]==24'h800000 && quotient[0]))quotient=quotient+1;
  quotient=quotient+$signed({24'b0,zp});
  if(relu && quotient<$signed({24'b0,zp}))quotient=$signed({24'b0,zp});
  return quotient<0 ? 8'd0 : quotient>255 ? 8'd255 : quotient[7:0];
 endfunction
 assign term_product=$signed(tap_a)*$signed(tap_w);
 assign dot_sum=$signed(sums[tap_lane])+$signed(term_product);
 always_comb begin
  input_bytes={24'b0,cfg[4][7:0]}*{27'b0,cfg[5][4:0]}*{27'b0,cfg[6][4:0]};
  weight_bytes=cfg[13]==1 ? {27'b0,cfg[7][4:0]}*{24'b0,cfg[4][7:0]} : {27'b0,cfg[7][4:0]}*{27'b0,cfg[6][4:0]}*9;
  output_bytes={27'b0,cfg[9][4:0]}*{27'b0,cfg[10][4:0]}*{27'b0,cfg[7][4:0]};
  valid_cfg=cfg[13]<=1 && cfg[7]>=1 && cfg[7]<=16 && cfg[11]<=255 && cfg[12]<=255 &&
   ((cfg[13]==0 && cfg[4]>=1 && cfg[4]<=28 && cfg[5]>=1 && cfg[5]<=28 && cfg[6]>=1 && cfg[6]<=16 && cfg[8]>=1 && cfg[8]<=2 && cfg[9]>=1 && cfg[9]<=(cfg[8]==2 ? (cfg[4]+1)>>1 : cfg[4]) && cfg[10]>=1 && cfg[10]<=(cfg[8]==2 ? (cfg[5]+1)>>1 : cfg[5])) ||
    (cfg[13]==1 && cfg[4]>=1 && cfg[4]<=144 && cfg[5]==1 && cfg[6]==1 && cfg[9]==1 && cfg[10]==1)) &&
   range_ok(cfg[0],input_bytes) && range_ok(cfg[1],weight_bytes) && range_ok(cfg[2],cfg[7]*8) && range_ok(cfg[3],output_bytes) &&
   !overlap(cfg[3],output_bytes,cfg[0],input_bytes) && !overlap(cfg[3],output_bytes,cfg[1],weight_bytes) && !overlap(cfg[3],output_bytes,cfg[2],cfg[7]*8);
  cols=cfg[13]==1 ? 1 : cfg[9]-{26'b0,ox}>=4 ? 4 : 3'(cfg[9]-{26'b0,ox});
  chunk_len=cfg[13]==1 ? ({1'b0,cfg[4][7:0]}-{1'b0,feature})>=12 ? 12 : 4'(({1'b0,cfg[4][7:0]}-{1'b0,feature})) : 9;
  last_chunk=cfg[13]==1 ? {24'b0,feature}+{28'b0,chunk_len}==cfg[4] : {27'b0,ic}+1==cfg[6];
  center_y={1'b0,oy}<<(cfg[8]==2);center_x=({1'b0,ox}+{5'b0,lane})<<(cfg[8]==2);
  ky_first=center_y==0 ? 1 : 0;ky_last={25'b0,center_y}+1>=cfg[5] ? 1 : 2;
  kx_first=center_x==0 ? 1 : 0;kx_last={25'b0,center_x}+1>=cfg[4] ? 1 : 2;
  last_tap=cfg[13]==1 ? ftap+1==chunk_len : ky==ky_last && kx==kx_last && {1'b0,lane}+1==cols;
  noc=oc;nic=ic;noy=oy;nox=ox;nfeature=feature;next_exists=1;
  if(cfg[13]==1)begin
   if(!last_chunk)nfeature=feature+{4'b0,chunk_len};
   else if({27'b0,oc}+1<cfg[7])begin noc=oc+1;nfeature=0;end
   else next_exists=0;
  end else if(!last_chunk)nic=ic+1;
  else begin
   nic=0;
   if({26'b0,ox}+{29'b0,cols}<cfg[9])nox=ox+{3'b0,cols};
   else if({26'b0,oy}+1<cfg[10])begin nox=0;noy=oy+1;end
   else if({27'b0,oc}+1<cfg[7])begin noc=oc+1;nox=0;noy=0;end
   else next_exists=0;
  end
  ncols=cfg[13]==1 ? 1 : cfg[9]-{26'b0,box[load_bank]}>=4 ? 4 : 3'(cfg[9]-{26'b0,box[load_bank]});
  load_len=cfg[13]==1 ? ({1'b0,cfg[4][7:0]}-{1'b0,bfeature[load_bank]})>=12 ? 12 : 4'(({1'b0,cfg[4][7:0]}-{1'b0,bfeature[load_bank]})) : 9;
  span=cfg[13]==1 ? load_len : ({1'b0,ncols}-1)*{2'b0,cfg[8][1:0]}+3;
  row_y=$signed({3'b0,boy[load_bank]} << (cfg[8]==2))+$signed({7'b0,load_row})-9'sd1;
  x_first=$signed({3'b0,box[load_bank]} << (cfg[8]==2))-9'sd1;
  x_end=x_first+$signed({5'b0,span});
  row_base={1'b0,cfg[0][12:0]}+14'(bic[load_bank])*14'(plane)+14'(row_y)*14'(cfg[4][7:0]);
  activation_index=cfg[13]==1 ? {1'b0,ftap} : 5'(ky*9+{3'b0,lane}*cfg[8][1:0]+kx);
  inside_image=cfg[13]==1 || (
   $signed({3'b0,oy} << (cfg[8]==2))+$signed({7'b0,ky})-1>=0 &&
   $signed({3'b0,oy} << (cfg[8]==2))+$signed({7'b0,ky})-1<$signed(cfg[5]) &&
   $signed(({3'b0,ox}+{7'b0,lane}) << (cfg[8]==2))+$signed({7'b0,kx})-1>=0 &&
   $signed(({3'b0,ox}+{7'b0,lane}) << (cfg[8]==2))+$signed({7'b0,kx})-1<$signed(cfg[4]));
  qbyte=requant(q2scaled,cfg[12][7:0],cfg[13]==0);
  assembled=pack_data;assembled[q2tag[1:0]*8+:8]=qbyte;
  assembled_be=pack_be|(4'b0001<<q2tag[1:0]);
  push_word=q2valid && (q2tag[1:0]==3 || {19'b0,q2tag}+1==output_bytes);
  busy_o=state!=IDLE;irq_o=done_o || fault;
  csr_rdata_o=0;
  case(csr_addr_i)
   8'h04:csr_rdata_o={29'b0,fault,done_o,busy_o};
   8'h40:csr_rdata_o=cycles;
   8'h44:csr_rdata_o=mac_cycles;
   8'h48:csr_rdata_o=issue_cycles;
   8'h4c:csr_rdata_o=memory_transactions;
   8'h50:csr_rdata_o=wait_cycles;
   default:if(csr_addr_i>=8 && csr_addr_i<=8'h3c)csr_rdata_o=cfg[(csr_addr_i-8)>>2];
  endcase
  csr_error_o=csr_addr_i[1:0]!=0 || !(csr_addr_i==0 || csr_addr_i==4 || (csr_addr_i>=8 && csr_addr_i<=8'h50)) ||
   (csr_we_i && (csr_addr_i==4 || csr_addr_i>=8'h40 || busy_o || blocked_i));
  req_o=0;we_o=0;be_o=4'hf;addr_o=0;wdata_o=0;write_selected=out_count!=0;
  if(write_selected)begin
   req_o=1;we_o=1;addr_o={19'h40000,13'(cfg[3][12:0]+out_offset[head])};be_o=out_be[head];wdata_o=out_data[head];
  end else case(load_state)
   WREQ:begin req_o=1;addr_o={19'h40000,weight_addr[12:0]};end
   MREQ:begin req_o=1;addr_o={19'h40000,13'(cfg[2][12:0]+{5'b0,boc[load_bank],3'b0})};end
   BREQ:begin req_o=1;addr_o={19'h40000,13'(cfg[2][12:0]+{5'b0,boc[load_bank],3'b0}+13'd4)};end
   AREQ:begin req_o=1;addr_o={19'h40000,act_addr[12:0]};end
   default:;
  endcase
  pop_word=req_o && gnt_i && write_selected;
 end
 task automatic launch(input logic target,input logic [4:0] c,i,input logic [5:0] y,x,input logic [7:0] f,input logic quant_needed);
  load_bank<=target;boc[target]<=c;bic[target]<=i;boy[target]<=y;box[target]<=x;bfeature[target]<=f;
  ready[target]<=0;need_quant<=quant_needed;load_row<=0;load_state<=WREQ;
  weight_start<={1'b0,cfg[1][12:0]}+(cfg[13]==1 ? 14'(c)*14'(cfg[4][7:0])+14'(f) : (14'(c)*14'(cfg[6][4:0])+14'(i))*14'd9);
  weight_addr<=({1'b0,cfg[1][12:0]}+(cfg[13]==1 ? 14'(c)*14'(cfg[4][7:0])+14'(f) : (14'(c)*14'(cfg[6][4:0])+14'(i))*14'd9))&14'h3ffc;
  weight_end<={1'b0,cfg[1][12:0]}+(cfg[13]==1 ? 14'(c)*14'(cfg[4][7:0])+14'(f)+14'(({1'b0,cfg[4][7:0]}-{1'b0,f})>=12 ? 12 : ({1'b0,cfg[4][7:0]}-{1'b0,f})) : (14'(c)*14'(cfg[6][4:0])+14'(i))*14'd9+14'd9);
  for(int j=0;j<32;j++)act[target][j]<=cfg[11][7:0];
 endtask
 always_ff @(posedge clk_i or negedge rst_ni)begin
  if(!rst_ni)begin
   state<=IDLE;load_state<=BIDLE;done_o<=0;fault<=0;ready<=0;bank<=0;load_bank<=0;need_quant<=0;command_valid<=0;
   oc<=0;ic<=0;oy<=0;ox<=0;feature<=0;ky<=0;kx<=0;lane<=0;ftap<=0;output_base<=0;plane<=0;
   weight_start<=0;weight_addr<=0;weight_end<=0;load_row<=0;act_addr<=0;clip_start<=0;clip_end<=0;row_logical_start<=0;
   cycles<=0;mac_cycles<=0;issue_cycles<=0;memory_transactions<=0;wait_cycles<=0;
   pending<=0;pending_write<=0;pending_type<=BIDLE;pending_bank<=0;pending_addr<=0;pending_weight_start<=0;pending_clip_start<=0;pending_clip_end<=0;pending_logical<=0;pending_row<=0;pending_len<=0;pending_span<=0;
   tap_valid<=0;tap_final<=0;tap_inside<=0;tap_lane<=0;tap_a<=0;tap_w<=0;tap_m<=0;tap_b<=0;tap_tag<=0;
   q0valid<=0;q1valid<=0;q2valid<=0;q0acc<=0;q0m<=0;q0b<=0;q1b<=0;q1product<=0;q2scaled<=0;q0tag<=0;q1tag<=0;q2tag<=0;
   head<=0;tail<=0;out_count<=0;pack_data<=0;pack_be<=0;
   for(int j=0;j<14;j++)cfg[j]<=0;
   for(int j=0;j<4;j++)sums[j]<=0;
   for(int b=0;b<2;b++)begin
    mult[b]<=0;bias[b]<=0;boc[b]<=0;bic[b]<=0;boy[b]<=0;box[b]<=0;bfeature[b]<=0;out_data[b]<=0;out_be[b]<=0;out_offset[b]<=0;
    for(int j=0;j<32;j++)act[b][j]<=0;
    for(int j=0;j<12;j++)weights[b][j]<=0;
   end
  end else begin
   tap_valid<=0;q0valid<=0;q1valid<=q0valid;q2valid<=q1valid;
   pending<=req_o && gnt_i;
   if(busy_o)cycles<=cycles+1;
   if(busy_o && state==WAIT_TILE)wait_cycles<=wait_cycles+1;
   if(req_o && gnt_i)begin
    memory_transactions<=memory_transactions+1;
    pending_write<=write_selected;pending_type<=load_state;pending_bank<=load_bank;pending_addr<={1'b0,addr_o[12:0]};pending_weight_start<=weight_start;
    pending_clip_start<=clip_start;pending_clip_end<=clip_end;pending_logical<=row_logical_start;pending_row<=load_row;pending_len<=load_len;pending_span<=span;
   end
   if(pending && rvalid_i && !pending_write && !error_i)case(pending_type)
    WREQ:for(int b=0;b<4;b++)if(pending_addr+14'(b)>=pending_weight_start && pending_addr+14'(b)<pending_weight_start+{10'b0,pending_len})
     weights[pending_bank][4'(pending_addr+14'(b)-pending_weight_start)]<=rdata_i[b*8+:8];
    MREQ:mult[pending_bank]<=rdata_i;
    BREQ:bias[pending_bank]<=rdata_i;
    AREQ:for(int b=0;b<4;b++)if(pending_addr+14'(b)>=pending_clip_start && pending_addr+14'(b)<pending_clip_end)
     act[pending_bank][5'((cfg[13]==1 ? 0 : int'(pending_row)*9)+pending_addr+14'(b)-pending_logical)]<=rdata_i[b*8+:8];
    default:;
   endcase
   if(tap_valid)begin
    if(tap_inside)mac_cycles<=mac_cycles+1;
    sums[tap_lane]<=tap_final ? 0 : dot_sum;
    if(tap_final)begin q0valid<=1;q0acc<=dot_sum;q0m<=tap_m;q0b<=tap_b;q0tag<=tap_tag;end
   end
   if(q0valid)begin q1product<=$signed(q0acc)*$signed(q0m);q1b<=q0b;q1tag<=q0tag;end
   if(q1valid)begin q2scaled<=q1product+$signed(q1b);q2tag<=q1tag;end
   if(q2valid)begin
    if(push_word)begin pack_data<=0;pack_be<=0;end
    else begin pack_data<=assembled;pack_be<=assembled_be;end
   end
   if(push_word)begin out_data[tail]<=assembled;out_be[tail]<=assembled_be;out_offset[tail]<={q2tag[12:2],2'b0};tail<=!tail;end
   if(pop_word)head<=!head;
   case({push_word,pop_word})
    2'b10:out_count<=out_count+1;
    2'b01:out_count<=out_count-1;
    default:;
   endcase
   case(state)
    START:begin
     cycles<=command_valid ? 1 : 0;mac_cycles<=0;issue_cycles<=0;memory_transactions<=0;wait_cycles<=0;
     ready<=0;bank<=0;oc<=0;ic<=0;oy<=0;ox<=0;feature<=0;ky<=0;kx<=0;lane<=0;ftap<=0;output_base<=0;
     plane<={8'b0,cfg[4][4:0]}*{8'b0,cfg[5][4:0]};
     pending<=0;tap_valid<=0;q0valid<=0;q1valid<=0;q2valid<=0;head<=0;tail<=0;out_count<=0;pack_be<=0;pack_data<=0;
     for(int j=0;j<4;j++)sums[j]<=0;
     fault<=!command_valid;
     if(command_valid)begin launch(0,0,0,0,0,0,1);state<=WAIT_TILE;end
     else begin state<=IDLE;load_state<=BIDLE;end
    end
    WAIT_TILE:if(ready[bank])begin
     state<=RUN;ky<=ky_first;kx<=ox==0 ? 1 : 0;lane<=0;ftap<=0;
     if(next_exists)begin
      launch(!bank,noc,nic,noy,nox,nfeature,noc!=oc);
      if(noc==oc)begin mult[!bank]<=mult[bank];bias[!bank]<=bias[bank];end
     end
    end
    RUN:begin
     // After a direct bank handoff, start the following prefetch immediately.
     if(next_exists && load_state==BIDLE && !ready[!bank])begin
      launch(!bank,noc,nic,noy,nox,nfeature,noc!=oc);
      if(noc==oc)begin mult[!bank]<=mult[bank];bias[!bank]<=bias[bank];end
     end
     issue_cycles<=issue_cycles+1;tap_valid<=1;tap_inside<=inside_image;tap_lane<=cfg[13]==1 ? 0 : lane;
     tap_a<=$signed({1'b0,act[bank][activation_index]})-$signed({1'b0,cfg[11][7:0]});
     tap_w<=weights[bank][cfg[13]==1 ? ftap : 4'(ky*3+kx)];tap_m<=mult[bank];tap_b<=bias[bank];
     tap_final<=last_chunk && (cfg[13]==1 ? ftap+1==chunk_len : ky==ky_last && kx==kx_last);
     tap_tag<=output_base+{11'b0,lane};
     if(last_tap)begin
      ready[bank]<=0;bank<=!bank;
      state<=!next_exists ? DRAIN : ready[!bank] ? RUN : WAIT_TILE;
      if(next_exists && ready[!bank])begin
       ky<=noy==0 ? 1 : 0;kx<=nox==0 ? 1 : 0;lane<=0;ftap<=0;
      end
      oc<=noc;ic<=nic;oy<=noy;ox<=nox;feature<=nfeature;
      if(last_chunk)output_base<=output_base+{10'b0,cols};
     end else if(cfg[13]==1)ftap<=ftap+1;
     else if(kx<kx_last)kx<=kx+1;
     else if(ky<ky_last)begin kx<=kx_first;ky<=ky+1;end
     else begin lane<=lane+1;ky<=ky_first;kx<=0;end
    end
    DRAIN:if(!tap_valid && !q0valid && !q1valid && !q2valid && out_count==0 && pack_be==0 && !pending && load_state==BIDLE)begin state<=IDLE;done_o<=1;end
    default:;
   endcase
   // Loader sends a new read on each grant and tracks each response separately.
   if(req_o && gnt_i && !write_selected)case(load_state)
    WREQ:if(weight_addr+4>=weight_end)load_state<=need_quant ? MREQ : PREP;else weight_addr<=weight_addr+4;
    MREQ:load_state<=BREQ;
    BREQ:load_state<=PREP;
    AREQ:if(act_addr+4>=clip_end)begin
      if(cfg[13]==1)load_state<=COMPLETE;
      else begin load_row<=load_row+1;load_state<=PREP;end
     end else act_addr<=act_addr+4;
    default:;
   endcase
   if(load_state==PREP)begin
    if(cfg[13]==1)begin
     row_logical_start<={1'b0,cfg[0][12:0]}+{6'b0,bfeature[load_bank]};clip_start<={1'b0,cfg[0][12:0]}+{6'b0,bfeature[load_bank]};
     clip_end<={1'b0,cfg[0][12:0]}+{6'b0,bfeature[load_bank]}+{10'b0,load_len};act_addr<=({1'b0,cfg[0][12:0]}+{6'b0,bfeature[load_bank]})&14'h3ffc;load_state<=AREQ;
    end else if(load_row==3)load_state<=COMPLETE;
    else if(row_y<0 || row_y>=$signed(cfg[5]) || x_end<=0 || x_first>=$signed(cfg[4]))load_row<=load_row+1;
    else begin
     row_logical_start<=row_base+14'(x_first);
     clip_start<=row_base+(x_first<0 ? 14'd0 : 14'(x_first));
     clip_end<=row_base+(x_end>$signed(cfg[4]) ? 14'(cfg[4][7:0]) : 14'(x_end));
     act_addr<=(row_base+(x_first<0 ? 14'd0 : 14'(x_first)))&14'h3ffc;load_state<=AREQ;
    end
   end
   if(load_state==COMPLETE && !pending)begin ready[load_bank]<=1;load_state<=BIDLE;end
   if(csr_req_i && csr_we_i && !csr_error_o)begin
    if(csr_addr_i>=8 && csr_addr_i<=8'h3c)cfg[(csr_addr_i-8)>>2]<=csr_wdata_i;
    if(csr_addr_i==0)begin
     if(csr_wdata_i[1])begin done_o<=0;fault<=0;end
     if(csr_wdata_i[0])begin
      done_o<=0;fault<=0;command_valid<=valid_cfg;state<=START;
     end
    end
   end
   if((pending && rvalid_i && busy_o && error_i) || (push_word && !pop_word && out_count==2))begin
    state<=IDLE;load_state<=BIDLE;fault<=1;done_o<=0;tap_valid<=0;q0valid<=0;q1valid<=0;q2valid<=0;out_count<=0;pack_be<=0;
   end
  end
 end
endmodule
