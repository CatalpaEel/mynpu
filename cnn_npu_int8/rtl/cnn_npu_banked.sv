`timescale 1ns/1ps
// Elastic two-read-port engine. These are REQUEST ports, not extra macro ports:
// the bank fabric grants independent banks in parallel and arbitrates conflicts.
// Weights/activation responses are retained until both are available. The last
// response bypasses its register into the MAC, removing a separate MAC FSM bubble.
module cnn_npu_banked #(
  parameter integer LANES=4, MAX_LAYERS=8, SRAM_BYTES=16384, ACT_CACHE_WORDS=1
)(
  input logic clk_i,rst_ni,
  input logic reg_req_i,reg_we_i,
  input logic [4:0] reg_addr_i,
  input logic [31:0] reg_wdata_i,
  output logic [31:0] reg_rdata_o,
  output logic irq_o,busy_o,
  input logic host_write_i,
  input logic [13:0] host_addr_i,
  output logic [1:0] req_o,we_o,
  output logic [13:0] addr_o[0:1],
  output logic [3:0] be_o[0:1],
  output logic [31:0] wdata_o[0:1],
  input logic [1:0] gnt_i,rvalid_i,
  input logic [31:0] rdata_i[0:1]
);
  typedef enum logic[4:0] {IDLE,DREQ,DWAIT,INIT,PREQ,PWAIT,GINIT,
    TERM,PAIR,RMUL,RSHIFT,RCLAMP,OUT,ADV,DONE,ERROR} state_t;
  state_t state_q;
  logic busy_q,done_q,error_q,irq_en_q;
  logic[31:0] desc_base_q,cycle_q,desc_q[0:8],mac_count_q;
  logic[7:0] layers_q,layer_q,oc_q,oy_q,ox_q,ci_q;
  logic[3:0] di_q,lane_q,count_q;
  logic[1:0] ky_q,kx_q,param_q;
  logic[13:0] ib_q,ob_q,wb_q,bb_q,mb_q,sb_q;
  logic[7:0] ih_q,iw_q,ic_q,ocount_q,oh_q,ow_q,stride_q,flags_q,iz_q,oz_q,qmax_q;
  logic[15:0] input_plane_q,output_plane_q,y_step_q,x_step_q;
  logic signed[31:0] bias_q[0:LANES-1],mult_q[0:LANES-1];
  wire signed[31:0] acc_q[0:LANES-1];
  logic[7:0] shift_q[0:LANES-1],out_q[0:LANES-1];
  logic signed[7:0] weight_q[0:LANES-1],mac_weight[0:LANES-1];
  logic[7:0] activation_q,mac_activation;
  logic signed[8:0] centered;
  logic signed[63:0] product_q;
  logic signed[31:0] scaled_q;
  integer quant_i,iy,ix,act_addr,weight_addr,term_index,terms,param_addr,out_addr;
  logic padding,cache_hit;
  logic[ACT_CACHE_WORDS-1:0] cache_valid_q;
  logic[11:0] cache_tag_q[0:ACT_CACHE_WORDS-1];
  logic[31:0] cache_data_q[0:ACT_CACHE_WORDS-1];
  integer cache_index,out_cache_index,host_cache_index;
  logic[13:0] act_addr_q,active_addr;
  logic act_sent_q,act_done_q,w0_sent_q,w1_sent_q,w0_done_q,w1_done_q;
  logic weight_response_group_q,need_second,all_ready,mac_enable,send_second;
  function automatic[7:0] byte_of(input logic[31:0] w,input integer a);
    byte_of=w[(a&3)*8+:8];
  endfunction
  function automatic integer rounded(input logic signed[63:0] v,input integer s);
    logic signed[63:0] h;
    if(s==0) rounded=v;else begin h=64'sd1<<<(s-1);rounded=(v+h)>>>s;end
  endfunction
  function automatic logic range_ok(input logic[31:0] base,input integer size);
    range_ok=(base<=SRAM_BYTES)&&(size>=0)&&(size<=SRAM_BYTES-base);
  endfunction
  function automatic logic valid_desc;
    integer ih,iw,ic,oc,oh,ow,fl,nb,ni,no;
    begin
      ih=desc_q[6][7:0];iw=desc_q[6][15:8];ic=desc_q[6][23:16];oc=desc_q[6][31:24];
      oh=desc_q[7][7:0];ow=desc_q[7][15:8];fl=desc_q[7][31:24];
      ni=(fl&1)?ic:ih*iw*ic;no=(fl&1)?oc:oh*ow*oc;
      nb=((oc+3)/4)*4*ic*((fl&1)?1:9);
      valid_desc=ih>0&&iw>0&&ic>0&&oc>0&&oh>0&&ow>0&&desc_q[7][23:16]>0&&
        ((fl&~7)==0)&&(fl&4)&&((desc_q[2]&3)==0)&&((desc_q[3]&3)==0)&&((desc_q[4]&3)==0)&&
        (!(fl&1)||(ih==1&&iw==1&&oh==1&&ow==1))&&
        range_ok(desc_q[0],ni)&&range_ok(desc_q[1],no)&&range_ok(desc_q[2],nb)&&
        range_ok(desc_q[3],oc*4)&&range_ok(desc_q[4],oc*4)&&range_ok(desc_q[5],oc);
    end
  endfunction
  task automatic advance_term;
    begin
      if(flags_q&1) begin
        if(ci_q+1<ic_q) begin ci_q<=ci_q+1;state_q<=TERM;end
        else begin lane_q<=0;state_q<=RMUL;end
      end else if(kx_q<2) begin kx_q<=kx_q+1;state_q<=TERM;end
      else if(ky_q<2) begin kx_q<=0;ky_q<=ky_q+1;state_q<=TERM;end
      else if(ci_q+1<ic_q) begin kx_q<=0;ky_q<=0;ci_q<=ci_q+1;state_q<=TERM;end
      else begin lane_q<=0;state_q<=RMUL;end
    end
  endtask
  assign busy_o=busy_q;
  // Errors also wake a sleeping CPU; software checks STATUS before accepting DONE.
  assign irq_o=(done_q||error_q)&&irq_en_q;
  always_comb begin
    case(reg_addr_i[4:2])
      0:reg_rdata_o={30'd0,irq_en_q,1'b0};
      1:reg_rdata_o={29'd0,error_q,done_q,busy_q};
      4:reg_rdata_o=desc_base_q;
      5:reg_rdata_o=layers_q;
      6:reg_rdata_o=cycle_q;
      7:reg_rdata_o={31'd0,error_q};
      default:reg_rdata_o=0;
    endcase
  end
  always_comb begin
    iy=y_step_q+ky_q-1;ix=x_step_q+kx_q-1;
    padding=!(flags_q&1)&&((iy<0)||(ix<0)||(iy>=ih_q)||(ix>=iw_q));
    act_addr=(flags_q&1)?ib_q+ci_q:ib_q+ci_q*input_plane_q+iy*iw_q+ix;
    terms=ic_q*((flags_q&1)?1:9);
    term_index=(flags_q&1)?ci_q:ci_q*9+ky_q*3+kx_q;
    weight_addr=wb_q+((oc_q/4)*terms+term_index)*4;
    param_addr=(param_q==0)?bb_q+(oc_q+lane_q)*4:
               (param_q==1)?mb_q+(oc_q+lane_q)*4:sb_q+oc_q+lane_q;
    out_addr=ob_q+((flags_q&1)?oc_q+lane_q:(oc_q+lane_q)*output_plane_q+oy_q*ow_q+ox_q);
    // TERM registers the address when starting the elastic read pair. PAIR
    // byte selection/cache-fill/MAC must not recompute oy*stride*width in the
    // SRAM-response-to-accumulator timing path.
    active_addr=(state_q==PAIR)?act_addr_q:act_addr;
    cache_index=(active_addr>>2)&(ACT_CACHE_WORDS-1);
    out_cache_index=(out_addr>>2)&(ACT_CACHE_WORDS-1);
    host_cache_index=(host_addr_i>>2)&(ACT_CACHE_WORDS-1);
    cache_hit=cache_valid_q[cache_index]&&(cache_tag_q[cache_index]==(active_addr>>2));
    need_second=(count_q>4);
    send_second=w0_sent_q&&(w0_done_q||(rvalid_i[0]&&!weight_response_group_q))&&need_second&&!w1_sent_q;
    req_o=0;we_o=0;
    for(integer n=0;n<2;n++) begin addr_o[n]=0;be_o[n]=4'hf;wdata_o[n]=0;end
    if(state_q==DREQ&&range_ok(desc_base_q,layers_q*36)) begin
      req_o[0]=1;addr_o[0]=desc_base_q+layer_q*36+di_q*4;
    end
    if(state_q==PREQ) begin req_o[0]=1;addr_o[0]=param_addr;end
    if(state_q==TERM&&!padding) begin
      req_o[0]=1;addr_o[0]=weight_addr;
      req_o[1]=!cache_hit;addr_o[1]=act_addr;
    end
    if(state_q==PAIR) begin
      req_o[0]=!w0_sent_q||send_second;
      addr_o[0]=weight_addr+(send_second?terms*4:0);
      req_o[1]=!act_sent_q;addr_o[1]=act_addr_q;
    end
    if(state_q==OUT) begin
      req_o[0]=1;we_o[0]=1;addr_o[0]=out_addr;
      be_o[0]=4'b1<<(out_addr&3);wdata_o[0]={24'd0,out_q[lane_q]}<<((out_addr&3)*8);
    end
    all_ready=(act_done_q||rvalid_i[1])&&
      (w0_done_q||(rvalid_i[0]&&!weight_response_group_q))&&
      (!need_second||w1_done_q||(rvalid_i[0]&&weight_response_group_q));
    mac_enable=(state_q==PAIR)&&all_ready;
    mac_activation=act_done_q?activation_q:byte_of(rdata_i[1],act_addr_q);
    centered=$signed({1'b0,mac_activation})-$signed({1'b0,iz_q});
    for(integer l=0;l<LANES;l++) begin
      mac_weight[l]=weight_q[l];
      if(rvalid_i[0]&&((l+(oc_q&3))/4==weight_response_group_q)) mac_weight[l]=byte_of(rdata_i[0],l+(oc_q&3));
    end
  end
  generate for(genvar l=0;l<LANES;l++) begin:g_mac
    cnn_npu_lane_mac i_mac(.clk_i(clk_i),.rst_ni(rst_ni),.load_i(state_q==GINIT),
      .mac_i(mac_enable&&(l<count_q)),.activation_i(centered),.weight_i(mac_weight[l]),
      .bias_i(bias_q[l]),.acc_o(acc_q[l]));
  end endgenerate
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      state_q<=IDLE;busy_q<=0;done_q<=0;error_q<=0;irq_en_q<=0;desc_base_q<=0;
      cycle_q<=0;mac_count_q<=0;layers_q<=6;layer_q<=0;di_q<=0;lane_q<=0;count_q<=0;
      oc_q<=0;oy_q<=0;ox_q<=0;ci_q<=0;ky_q<=0;kx_q<=0;param_q<=0;
      ib_q<=0;ob_q<=0;wb_q<=0;bb_q<=0;mb_q<=0;sb_q<=0;
      ih_q<=0;iw_q<=0;ic_q<=0;ocount_q<=0;oh_q<=0;ow_q<=0;stride_q<=0;flags_q<=0;
      input_plane_q<=0;output_plane_q<=0;y_step_q<=0;x_step_q<=0;
      iz_q<=0;oz_q<=0;qmax_q<=0;product_q<=0;scaled_q<=0;activation_q<=0;act_addr_q<=0;
      cache_valid_q<=0;
      for(integer c=0;c<ACT_CACHE_WORDS;c++)begin cache_tag_q[c]<=0;cache_data_q[c]<=0;end
      act_sent_q<=0;act_done_q<=0;w0_sent_q<=0;w1_sent_q<=0;w0_done_q<=0;w1_done_q<=0;weight_response_group_q<=0;
      for(integer i=0;i<9;i++) desc_q[i]<=0;
      for(integer l=0;l<LANES;l++) begin bias_q[l]<=0;mult_q[l]<=0;shift_q[l]<=0;weight_q[l]<=0;out_q[l]<=0;end
    end else begin
      if(busy_q)cycle_q<=cycle_q+1;
      if(mac_enable)mac_count_q<=mac_count_q+count_q;
      case(state_q)
        IDLE,DONE,ERROR: ;
        DREQ:if(!range_ok(desc_base_q,layers_q*36)||(desc_base_q&3)!=0)state_q<=ERROR;
              else if(gnt_i[0])state_q<=DWAIT;
        DWAIT:if(rvalid_i[0])begin
          desc_q[di_q]<=rdata_i[0];
          if(di_q==8)state_q<=INIT;else begin di_q<=di_q+1;state_q<=DREQ;end
        end
        INIT:if(!valid_desc())state_q<=ERROR;else begin
          ib_q<=desc_q[0];ob_q<=desc_q[1];wb_q<=desc_q[2];bb_q<=desc_q[3];mb_q<=desc_q[4];sb_q<=desc_q[5];
          ih_q<=desc_q[6][7:0];iw_q<=desc_q[6][15:8];ic_q<=desc_q[6][23:16];ocount_q<=desc_q[6][31:24];
          oh_q<=desc_q[7][7:0];ow_q<=desc_q[7][15:8];stride_q<=desc_q[7][23:16];flags_q<=desc_q[7][31:24];
          input_plane_q<=desc_q[6][7:0]*desc_q[6][15:8];
          output_plane_q<=desc_q[7][7:0]*desc_q[7][15:8];
          iz_q<=desc_q[8][7:0];oz_q<=desc_q[8][15:8];qmax_q<=desc_q[8][23:16]?desc_q[8][23:16]:127;
          count_q<=(desc_q[6][31:24]<LANES)?desc_q[6][31:24]:LANES;
          oc_q<=0;oy_q<=0;ox_q<=0;lane_q<=0;param_q<=0;cache_valid_q<=0;state_q<=PREQ;
        end
        PREQ:if(gnt_i[0])state_q<=PWAIT;
        PWAIT:if(rvalid_i[0])begin
          if(param_q==0)begin bias_q[lane_q]<=$signed(rdata_i[0]);param_q<=1;state_q<=PREQ;end
          else if(param_q==1)begin mult_q[lane_q]<=$signed(rdata_i[0]);param_q<=2;state_q<=PREQ;end
          else if(byte_of(rdata_i[0],param_addr)>63)state_q<=ERROR;
          else begin
            shift_q[lane_q]<=byte_of(rdata_i[0],param_addr);param_q<=0;
            if(lane_q+1<count_q)begin lane_q<=lane_q+1;state_q<=PREQ;end
            else begin lane_q<=0;state_q<=GINIT;end
          end
        end
        GINIT:begin
          y_step_q<=oy_q*stride_q;x_step_q<=ox_q*stride_q;
          ci_q<=0;ky_q<=0;kx_q<=0;lane_q<=0;state_q<=TERM;
        end
        TERM:if(padding)advance_term();else begin
          act_addr_q<=act_addr;
          act_sent_q<=cache_hit||gnt_i[1];act_done_q<=cache_hit;
          if(cache_hit)activation_q<=byte_of(cache_data_q[cache_index],act_addr);
          w0_sent_q<=gnt_i[0];w1_sent_q<=0;w0_done_q<=0;w1_done_q<=0;
          weight_response_group_q<=0;state_q<=PAIR;
        end
        PAIR:begin
          if(gnt_i[1])act_sent_q<=1;
          if(gnt_i[0])begin
            if(send_second)w1_sent_q<=1;else w0_sent_q<=1;
            weight_response_group_q<=send_second;
          end
          if(rvalid_i[1])begin
            act_done_q<=1;activation_q<=byte_of(rdata_i[1],act_addr_q);
            cache_valid_q[cache_index]<=1;cache_tag_q[cache_index]<=act_addr_q>>2;cache_data_q[cache_index]<=rdata_i[1];
          end
          if(rvalid_i[0])begin
            if(weight_response_group_q)w1_done_q<=1;else w0_done_q<=1;
            for(integer l=0;l<LANES;l++)if((l+(oc_q&3))/4==weight_response_group_q)weight_q[l]<=byte_of(rdata_i[0],l+(oc_q&3));
          end
          if(all_ready)advance_term();
        end
        RMUL:begin product_q<=$signed(acc_q[lane_q])*$signed(mult_q[lane_q]);state_q<=RSHIFT;end
        RSHIFT:begin scaled_q<=rounded(product_q,shift_q[lane_q]);state_q<=RCLAMP;end
        RCLAMP:begin
          quant_i=scaled_q+$signed({1'b0,oz_q});
          if((flags_q&2)&&(quant_i<$signed({1'b0,oz_q})))quant_i=oz_q;
          out_q[lane_q]<=(quant_i<0)?0:((quant_i>qmax_q)?qmax_q:quant_i);
          if(lane_q+1<count_q)begin lane_q<=lane_q+1;state_q<=RMUL;end
          else begin lane_q<=0;state_q<=OUT;end
        end
        OUT:if(gnt_i[0])begin
          // Retain unrelated input words across output positions. Only a write
          // to this exact cached logical word invalidates its entry.
          if(cache_tag_q[out_cache_index]==(out_addr>>2))cache_valid_q[out_cache_index]<=0;
          if(lane_q+1<count_q)lane_q<=lane_q+1;else begin lane_q<=0;state_q<=ADV;end
        end
        ADV:if(!(flags_q&1)&&ox_q+1<ow_q)begin ox_q<=ox_q+1;state_q<=GINIT;end
          else if(!(flags_q&1)&&oy_q+1<oh_q)begin oy_q<=oy_q+1;ox_q<=0;state_q<=GINIT;end
          else if(oc_q+LANES<ocount_q)begin
            oc_q<=oc_q+LANES;oy_q<=0;ox_q<=0;lane_q<=0;param_q<=0;
            count_q<=((ocount_q-oc_q-LANES)<LANES)?ocount_q-oc_q-LANES:LANES;state_q<=PREQ;
          end else if(layer_q+1<layers_q)begin layer_q<=layer_q+1;di_q<=0;state_q<=DREQ;end
          else begin busy_q<=0;done_q<=1;state_q<=DONE;end
        default:state_q<=ERROR;
      endcase
      if(state_q==ERROR)begin busy_q<=0;error_q<=1;end
      // CPU/SBA aliases snoop the same logical word tags, including a fill
      // returned in this cycle. No stale line survives a host write.
      if(host_write_i)begin
        if(cache_tag_q[host_cache_index]==(host_addr_i>>2))cache_valid_q[host_cache_index]<=0;
        if(state_q==PAIR&&rvalid_i[1]&&((act_addr_q>>2)==(host_addr_i>>2)))cache_valid_q[cache_index]<=0;
      end
      // Register commands come last so ERROR cleanup cannot overwrite restart.
      if(reg_req_i&&reg_we_i)case(reg_addr_i[4:2])
        0:begin
          irq_en_q<=reg_wdata_i[1];
          if(reg_wdata_i[2])begin done_q<=0;error_q<=0;if(!busy_q)state_q<=IDLE;end
          if(reg_wdata_i[0]&&!busy_q)begin
            done_q<=0;error_q<=0;cycle_q<=0;mac_count_q<=0;cache_valid_q<=0;layer_q<=0;di_q<=0;
            if(layers_q==0||layers_q>MAX_LAYERS)begin busy_q<=0;state_q<=ERROR;end
            else begin busy_q<=1;state_q<=DREQ;end
          end
        end
        4:if(!busy_q)desc_base_q<=reg_wdata_i;
        5:if(!busy_q)layers_q<=reg_wdata_i;
        default:;
      endcase
    end
  end
  initial if(!(LANES==1||LANES==2||LANES==4||LANES==8)||SRAM_BYTES!=16384||ACT_CACHE_WORDS<1||
             (ACT_CACHE_WORDS&(ACT_CACHE_WORDS-1))!=0)
    $fatal(1,"Banked NPU supports LANES=1/2/4/8 and 2x8KB physical memory");
endmodule
