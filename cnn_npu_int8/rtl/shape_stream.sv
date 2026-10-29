`timescale 1ns/1ps
// Generic tiled shape/stride I/O. Address generation, extension and byte packing
// only: no MAC, requantizer, activation or neural-network layer sequencer.
module shape_stream #(parameter integer CACHE_WORDS=32)(
  input logic clk_i,rst_ni,
  input logic cfg_write_i,
  input logic[9:0] cfg_addr_i,
  input logic[31:0] cfg_wdata_i,
  output logic[31:0] cfg_rdata_o,
  input logic arm_i,start_i,defer_i,commit_i,pair_i,
  input logic[1:0] pair_context_a_i,pair_context_b_i,
  input logic[13:0] pair_base_a_i,pair_base_b_i,
  input logic[3:0] pair_arm_mask_i,
  input logic[3:0] contexts_i,row_mask_i,
  input logic clear_error_i,invalidate_i,
  input logic[13:0] invalidate_addr_i,
  output logic busy_o,error_o,compute_safe_o,prefetch_busy_o,
  output logic[3:0] ready_o,reserved_o,read_locks_o,write_locks_o,
  output logic[3:0] ended_o,
  output logic[7:0] buffer_regs_o,
  input logic[31:0] registers_i[0:15][0:3],
  output logic[15:0] load_mask_o[0:1][0:3],
  output logic[31:0] load_data_o[0:1][0:3],
  output logic[1:0] load_reg_o[0:1],
  output logic[1:0] req_o,we_o,
  output logic[13:0] addr_o[0:1],
  output logic[3:0] be_o[0:1],
  output logic[31:0] wdata_o[0:1],
  input logic[1:0] gnt_i,rvalid_i,
  input logic[31:0] rdata_i[0:1]
);
  // Descriptor words: base, control, tile shape, tile row/column strides,
  // outer shape[3], outer strides[3], register base/strides, PE origin.
  // The shared memory is 16KB. Signed 16-bit addresses/strides also permit
  // masked negative padding; shapes/counts are unsigned 16-bit quantities.
  // Per-field validity and sticky cursor overflow prevent truncated aliases.
  logic[15:0] descriptor[0:3][0:12];
  logic[12:0] config_bad_q[0:3];
  logic[15:0] cursor[0:3],axis_base[0:3][1:2],index_q[0:3][0:2];
  logic[3:0] cursor_overflow_q;
  logic[1:2] axis_overflow_q[0:3];
  logic[1:0] reg_cursor[0:3],reg_base[0:3][0:2];
  logic[3:0] armed_q,ended_q,pending_q,row_mask_q;
  logic[1:0] active_q,waiting_q,deferred_q,staged_q;
  logic[15:0] staged_mask[0:1][0:3];
  logic[1:0] staged_reg[0:1];
  logic commit_all_ready,exchange_ok,start_allowed;
  logic[1:0] group_q[0:1];
  logic[1:0] selected_hi_q;
  wire[1:0] selected_q[0:1];
  for(genvar p=0;p<2;p++)assign selected_q[p]={selected_hi_q[p],1'(p)};
  logic[13:0] waiting_addr_q[0:1];
  logic[3:0] gathered_q[0:1],stored_q[0:1];
  logic[31:0] gathered_data[0:1][0:3];
  // A small word gather cache per physical request port. Lane data is latched
  // separately, so conflicting addresses cannot evict progress or deadlock.
  localparam integer CACHE_BITS=$clog2(CACHE_WORDS);
  localparam integer CACHE_ROWS=CACHE_WORDS/4;
  localparam integer ROW_BITS=(CACHE_ROWS>1)?$clog2(CACHE_ROWS):1;
  logic[CACHE_WORDS-1:0] cache_valid[0:1];
  logic[11-CACHE_BITS:0] cache_tag[0:1][0:3][0:CACHE_ROWS-1];
  logic[31:0] cache_data[0:1][0:3][0:CACHE_ROWS-1];
  logic[11:0] lookup_word[0:1][0:3];
  logic[ROW_BITS-1:0] lookup_row[0:1][0:3];
  logic[3:0] lookup_valid[0:1],lookup_hit[0:1];
  logic[31:0] lookup_data[0:1][0:3];
  logic[3:0] lane_valid[0:1],ready_lane[0:1],write_match[0:1];
  logic[15:0] lane_mask[0:1][0:3];
  logic[18:0] lane_address[0:1][0:3];
  logic[31:0] lane_data[0:1][0:3];
  logic[31:0] source_word[0:1][0:3];
  logic[1:0] format_bytes[0:1]; // log2(bytes)
  logic[2:0] group_count[0:1];
  logic[1:0] mapping[0:1];
  logic store[0:1],bad[0:1],complete[0:1],write_event;
  logic[3:0] response_hit[0:1];
  assign busy_o=(|pending_q)||(|active_q)||(|staged_q);
  assign prefetch_busy_o=|(active_q&deferred_q);
  assign compute_safe_o=!(|pending_q)&&!(|(active_q&~deferred_q));
  assign commit_all_ready=(contexts_i&ready_o)==contexts_i;
  assign exchange_ok=commit_i&&commit_all_ready&&reserved_o==contexts_i&&
    !(|(active_q&~(deferred_q&{complete[1],complete[0]})))&&!(|pending_q);
  assign start_allowed=start_i&&(!busy_o||exchange_ok);
  always_comb begin
    reserved_o=0;read_locks_o=0;write_locks_o=0;
    for(integer p=0;p<2;p++)begin
      if(active_q[p]&&!deferred_q[p])begin
        if(descriptor[selected_q[p]][1][3])read_locks_o[reg_cursor[selected_q[p]]]=1;
        else write_locks_o[reg_cursor[selected_q[p]]]=1;
      end
      if(deferred_q[p]&&(active_q[p]||staged_q[p]))reserved_o[selected_q[p]]=1;
    end
    for(integer c=0;c<4;c++)if(pending_q[c])begin
      if(descriptor[c][1][3])read_locks_o[reg_cursor[c]]=1;
      else write_locks_o[reg_cursor[c]]=1;
    end
  end
  // Fall-through input queue: publish directly on the read-response edge,
  // without forcing an extra staged-valid clock between every MAC and load.
  always_comb begin
    ready_o=0;buffer_regs_o=0;
    for(integer p=0;p<2;p++)if(staged_q[p]||(active_q[p]&&deferred_q[p]&&complete[p]))begin
      ready_o[selected_q[p]]=1;
      buffer_regs_o[selected_q[p]*2+:2]=staged_q[p]?staged_reg[p]:reg_cursor[selected_q[p]];
    end
  end
  assign ended_o=ended_q;
  assign write_event=(req_o[0]&&we_o[0]&&gnt_i[0])||(req_o[1]&&we_o[1]&&gnt_i[1]);
  always_comb begin
    cfg_rdata_o=0;
    if(cfg_addr_i[7:2]<13)begin
      case(cfg_addr_i[7:2])
        0,3,4,8,9,10:cfg_rdata_o={{16{descriptor[cfg_addr_i[9:8]][cfg_addr_i[7:2]][15]}},descriptor[cfg_addr_i[9:8]][cfg_addr_i[7:2]]};
        default:cfg_rdata_o={16'd0,descriptor[cfg_addr_i[9:8]][cfg_addr_i[7:2]]};
      endcase
    end
  end
  function automatic logic[16:0] address_add(input logic[15:0]a,b);
    address_add={a[15],a}+{b[15],b};
  endfunction
  function automatic logic[ROW_BITS-1:0] cache_row(input logic[13:0]address);
    cache_row=(CACHE_ROWS==1)?0:(address>>4);
  endfunction
  function automatic logic[31:0] extend_word(input logic[31:0]word_data,
      input logic[1:0]offset,input logic[2:0]format);
    logic[31:0] shifted;
    begin
      shifted=word_data>>(8*offset);
      case(format)
        0:extend_word={24'd0,shifted[7:0]};
        1:extend_word={{24{shifted[7]}},shifted[7:0]};
        2:extend_word={16'd0,shifted[15:0]};
        3:extend_word={{16{shifted[15]}},shifted[15:0]};
        default:extend_word=shifted;
      endcase
    end
  endfunction
  always_comb begin
    req_o=0;we_o=0;
    for(integer p=0;p<2;p++)begin
      integer c,nr,nc,origin_r,origin_c,rr,cc,physical_r,physical_c,pe,chosen,cache_index,bank;
      logic[9:0]ctl;
      logic signed[18:0]a,rs,cs;
      logic[31:0]value;
      logic found,hit;
      c=selected_q[p];ctl=descriptor[c][1];nr=descriptor[c][2][2:0];nc=descriptor[c][2][6:4];
      origin_r=descriptor[c][12][1:0];origin_c=descriptor[c][12][3:2];
      store[p]=ctl[3];mapping[p]=ctl[5:4];
      format_bytes[p]=(ctl[2:0]<2)?0:((ctl[2:0]<4)?1:2);
      group_count[p]=(mapping[p]==0)?(ctl[6]?nc:nr):1;
      lane_valid[p]=0;ready_lane[p]=0;response_hit[p]=0;write_match[p]=0;
      addr_o[p]=0;be_o[p]=0;wdata_o[p]=0;load_reg_o[p]=reg_cursor[c];
      bad[p]=active_q[p]&&(!armed_q[c]||ended_q[c]||(|config_bad_q[c])||cursor_overflow_q[c]||nr<1||nr>4||nc<1||nc>4||
        mapping[p]==3||ctl[7]||ctl[2:0]>4||descriptor[c][5]==0||descriptor[c][6]==0||descriptor[c][7]==0||(deferred_q[p]&&(store[p]||mapping[p]==0)));
      rs={{3{descriptor[c][3][15]}},descriptor[c][3]};
      cs={{3{descriptor[c][4][15]}},descriptor[c][4]};
      for(integer k=0;k<4;k++)begin
        lane_mask[p][k]=0;load_mask_o[p][k]=0;load_data_o[p][k]=0;
        rr=0;cc=0;a={{3{cursor[c][15]}},cursor[c]};
        if(mapping[p]==1)begin rr=k;a=a+k*rs;end
        else if(mapping[p]==2)begin cc=k;a=a+k*cs;end
        else if(ctl[6])begin rr=k;cc=group_q[p];a=a+k*rs+group_q[p]*cs;end
        else begin rr=group_q[p];cc=k;a=a+group_q[p]*rs+k*cs;end
        if(active_q[p]&&rr<nr&&cc<nc)begin
          for(integer tr=0;tr<4;tr++)for(integer tc=0;tc<4;tc++)begin
            physical_r=(origin_r+tr)%4;physical_c=(origin_c+tc)%4;pe=physical_r*4+physical_c;
            if(tr<nr&&tc<nc&&row_mask_q[physical_r]&&
               ((mapping[p]==1&&tr==rr)||(mapping[p]==2&&tc==cc)||
                (mapping[p]==0&&tr==rr&&tc==cc)))lane_mask[p][k][pe]=1;
          end
        end
        lane_valid[p][k]=|lane_mask[p][k];lane_address[p][k]=a;
        if(lane_valid[p][k]&&((|a[18:14])||
            (format_bytes[p]==1&&a[0])||(format_bytes[p]==2&&|a[1:0])))bad[p]=1;
        value=0;
        // For broadcast stores, take the first participating PE. FULL mapping
        // is the ordinary inverse of a load. Duplicate addresses: last lane wins.
        found=0;
        for(integer t=0;t<16;t++)if(lane_mask[p][k][t]&&!found)begin
          value=registers_i[t][reg_cursor[c]];found=1;
        end
        source_word[p][k]=value;
      end
      // Four shallow banks replace four full-depth asynchronous data reads.
      // Requests for the same word broadcast. Same-bank different-word hits
      // replay through the existing gathered flags, without losing progress.
      lookup_valid[p]=0;lookup_hit[p]=0;
      for(integer b=0;b<4;b++)begin
        lookup_row[p][b]=0;lookup_word[p][b]=0;
        for(integer k=0;k<4;k++)if(lane_valid[p][k]&&!gathered_q[p][k]&&
            lane_address[p][k][3:2]==b&&!lookup_valid[p][b])begin
          lookup_valid[p][b]=1;lookup_row[p][b]=cache_row(lane_address[p][k][13:0]);
          lookup_word[p][b]=lane_address[p][k][13:2];
        end
        cache_index=(int'(lookup_row[p][b])<<2)|b;
        lookup_hit[p][b]=lookup_valid[p][b]&&cache_valid[p][cache_index]&&
          cache_tag[p][b][lookup_row[p][b]]==lookup_word[p][b][11:CACHE_BITS];
        lookup_data[p][b]=cache_data[p][b][lookup_row[p][b]];
      end
      for(integer k=0;k<4;k++)begin
        bank=lane_address[p][k][3:2];
        hit=lookup_hit[p][bank]&&lookup_word[p][bank]==lane_address[p][k][13:2];
        response_hit[p][k]=waiting_q[p]&&rvalid_i[p]&&waiting_addr_q[p][13:2]==lane_address[p][k][13:2];
        lane_data[p][k]=gathered_data[p][k];
        if(!gathered_q[p][k])begin
          if(hit)lane_data[p][k]=extend_word(lookup_data[p][bank],lane_address[p][k][1:0],ctl[2:0]);
          else if(response_hit[p][k])lane_data[p][k]=extend_word(rdata_i[p],lane_address[p][k][1:0],ctl[2:0]);
        end
        ready_lane[p][k]=!lane_valid[p][k]||gathered_q[p][k]||hit||response_hit[p][k];
      end
      chosen=0;found=0;
      for(integer k=0;k<4;k++)if(lane_valid[p][k]&&
          (store[p]?!stored_q[p][k]:(!ready_lane[p][k]&&
            lookup_word[p][lane_address[p][k][3:2]]==lane_address[p][k][13:2]))&&!found)begin chosen=k;found=1;end
      addr_o[p]={lane_address[p][chosen][13:2],2'b00};
      req_o[p]=active_q[p]&&!bad[p]&&!waiting_q[p]&&found;we_o[p]=store[p];
      if(store[p])begin
        for(integer k=0;k<4;k++)if(lane_valid[p][k]&&!stored_q[p][k]&&
            lane_address[p][k][18:2]==lane_address[p][chosen][18:2])begin
          write_match[p][k]=1;
          for(integer b=0;b<4;b++)if(b<(1<<format_bytes[p]))begin
            be_o[p][lane_address[p][k][1:0]+b]=1;
            wdata_o[p][(lane_address[p][k][1:0]+b)*8+:8]=source_word[p][k][b*8+:8];
          end
        end
        complete[p]=active_q[p]&&((&(stored_q[p]|~lane_valid[p]))||
          (req_o[p]&&gnt_i[p]&&(&(stored_q[p]|write_match[p]|~lane_valid[p]))));
      end else begin
        be_o[p]=15;complete[p]=active_q[p]&&(&ready_lane[p])&&!bad[p];
        if(complete[p]&&!deferred_q[p])for(integer k=0;k<4;k++)begin
          load_mask_o[p][k]=lane_mask[p][k];load_data_o[p][k]=lane_data[p][k];
        end
      end
      // A prefetch never changes PE data. Explicit software COMMIT publishes
      // these four gathered values atomically; the PE retains exactly 4 regs.
      if(commit_i&&commit_all_ready&&ready_o[c]&&contexts_i[c])begin
        load_reg_o[p]=staged_q[p]?staged_reg[p]:reg_cursor[c];
        for(integer k=0;k<4;k++)begin
          load_mask_o[p][k]=staged_q[p]?staged_mask[p][k]:lane_mask[p][k];
          load_data_o[p][k]=staged_q[p]?gathered_data[p][k]:lane_data[p][k];
        end
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin
      armed_q<=0;ended_q<=0;pending_q<=0;active_q<=0;waiting_q<=0;deferred_q<=0;staged_q<=0;row_mask_q<=0;error_o<=0;
      cursor_overflow_q<=0;
      for(integer c=0;c<4;c++)begin
        cursor[c]<=0;reg_cursor[c]<=0;
        config_bad_q[c]<=0;axis_overflow_q[c]<=0;
        for(integer w=0;w<13;w++)descriptor[c][w]<=0;
        for(integer a=0;a<3;a++)begin index_q[c][a]<=0;reg_base[c][a]<=0;end
        for(integer a=1;a<3;a++)axis_base[c][a]<=0;
      end
      for(integer p=0;p<2;p++)begin
        selected_hi_q[p]<=0;group_q[p]<=0;gathered_q[p]<=0;stored_q[p]<=0;
        waiting_addr_q[p]<=0;cache_valid[p]<=0;staged_reg[p]<=0;
        for(integer k=0;k<4;k++)begin gathered_data[p][k]<=0;staged_mask[p][k]<=0;end
      end
    end else begin
      if(clear_error_i)error_o<=0;
      if(cfg_write_i&&cfg_addr_i[7:2]<13&&!busy_o)begin
        config_bad_q[cfg_addr_i[9:8]][cfg_addr_i[7:2]]<=0;
        case(cfg_addr_i[7:2])
          1:descriptor[cfg_addr_i[9:8]][1]<=cfg_wdata_i[15:0]&16'h3ff;
          2:descriptor[cfg_addr_i[9:8]][2]<=cfg_wdata_i[15:0]&16'h77;
          11:descriptor[cfg_addr_i[9:8]][11]<=cfg_wdata_i[15:0]&16'hff;
          12:descriptor[cfg_addr_i[9:8]][12]<=cfg_wdata_i[15:0]&16'hf;
          default:begin
            descriptor[cfg_addr_i[9:8]][cfg_addr_i[7:2]]<=cfg_wdata_i[15:0];
            case(cfg_addr_i[7:2])
              5,6,7:if(|cfg_wdata_i[31:16])begin config_bad_q[cfg_addr_i[9:8]][cfg_addr_i[7:2]]<=1;error_o<=1;end
              default:if(cfg_wdata_i[31:16]!={16{cfg_wdata_i[15]}})begin config_bad_q[cfg_addr_i[9:8]][cfg_addr_i[7:2]]<=1;error_o<=1;end
            endcase
          end
        endcase
      end
      if(pair_i&&!busy_o)begin
        descriptor[pair_context_a_i][0]<={2'd0,pair_base_a_i};
        descriptor[pair_context_b_i][0]<={2'd0,pair_base_b_i};
        config_bad_q[pair_context_a_i][0]<=0;config_bad_q[pair_context_b_i][0]<=0;
      end
      if((arm_i||pair_i)&&!busy_o)for(integer c=0;c<4;c++)if(pair_i?pair_arm_mask_i[c]:contexts_i[c])begin
        armed_q[c]<=1;ended_q[c]<=0;
        cursor_overflow_q[c]<=0;axis_overflow_q[c]<=0;
        cursor[c]<=pair_i&&c==pair_context_a_i?{2'd0,pair_base_a_i}:
                   pair_i&&c==pair_context_b_i?{2'd0,pair_base_b_i}:descriptor[c][0];
        reg_cursor[c]<=descriptor[c][11][1:0];
        for(integer a=0;a<3;a++)begin
          index_q[c][a]<=0;
          reg_base[c][a]<=descriptor[c][11][1:0];
        end
        for(integer a=1;a<3;a++)axis_base[c][a]<=pair_i&&c==pair_context_a_i?{2'd0,pair_base_a_i}:
                           pair_i&&c==pair_context_b_i?{2'd0,pair_base_b_i}:descriptor[c][0];
      end
      if(commit_i)begin
        if(!commit_all_ready)error_o<=1;
        else for(integer p=0;p<2;p++)if(staged_q[p]&&contexts_i[selected_q[p]])staged_q[p]<=0;
      end
      for(integer p=0;p<2;p++)begin
        integer c,chosen;
        logic[16:0]advance0,advance1,advance2;
        c=selected_q[p];chosen=p;
        advance0=address_add(cursor[c],descriptor[c][8]);
        advance1=address_add(axis_base[c][1],descriptor[c][9]);
        advance2=address_add(axis_base[c][2],descriptor[c][10]);
        if(waiting_q[p]&&rvalid_i[p])begin
          waiting_q[p]<=0;
          if(!descriptor[c][1][9])begin
            cache_valid[p][waiting_addr_q[p][2+:CACHE_BITS]]<=1;
            cache_tag[p][waiting_addr_q[p][3:2]][cache_row(waiting_addr_q[p])]<=waiting_addr_q[p][13:2+CACHE_BITS];
            cache_data[p][waiting_addr_q[p][3:2]][cache_row(waiting_addr_q[p])]<=rdata_i[p];
          end
        end
        if(!active_q[p]&&(pending_q[p]||pending_q[p+2]))begin
          chosen=pending_q[p]?p:p+2;selected_hi_q[p]<=chosen[1];pending_q[chosen]<=0;
          active_q[p]<=1;group_q[p]<=0;gathered_q[p]<=0;stored_q[p]<=0;
        end
        if(active_q[p])begin
          if(bad[p])begin error_o<=1;active_q[p]<=0;waiting_q[p]<=0;end
          else begin
            if(req_o[p]&&gnt_i[p])begin
              if(we_o[p])stored_q[p]<=stored_q[p]|write_match[p];
              else begin waiting_q[p]<=1;waiting_addr_q[p]<=addr_o[p];end
            end
            if(!store[p])for(integer k=0;k<4;k++)if(lane_valid[p][k]&&ready_lane[p][k])begin
              gathered_q[p][k]<=1;gathered_data[p][k]<=lane_data[p][k];
            end
            if(complete[p])begin
              gathered_q[p]<=0;stored_q[p]<=0;
              if(group_q[p]+3'd1<group_count[p])group_q[p]<=group_q[p]+1'b1;
              else begin
                active_q[p]<=0;
                if(deferred_q[p])begin
                  staged_q[p]<=!(commit_i&&commit_all_ready&&contexts_i[c]);staged_reg[p]<=reg_cursor[c];
                  for(integer k=0;k<4;k++)begin
                    staged_mask[p][k]<=lane_mask[p][k];gathered_data[p][k]<=lane_data[p][k];
                  end
                end
                // Nested three-dimensional counters. Axis 0 is innermost.
                if(index_q[c][0]+16'd1<descriptor[c][5])begin
                  index_q[c][0]<=index_q[c][0]+16'd1;cursor[c]<=advance0[15:0];
                  cursor_overflow_q[c]<=cursor_overflow_q[c]||(advance0[16]!=advance0[15]);
                  reg_cursor[c]<=reg_cursor[c]+descriptor[c][11][3:2];
                end else if(index_q[c][1]+16'd1<descriptor[c][6])begin
                  index_q[c][0]<=0;index_q[c][1]<=index_q[c][1]+1;
                  cursor[c]<=advance1[15:0];axis_base[c][1]<=advance1[15:0];
                  cursor_overflow_q[c]<=axis_overflow_q[c][1]||(advance1[16]!=advance1[15]);
                  axis_overflow_q[c][1]<=axis_overflow_q[c][1]||(advance1[16]!=advance1[15]);
                  reg_cursor[c]<=reg_base[c][1]+descriptor[c][11][5:4];reg_base[c][1]<=reg_base[c][1]+descriptor[c][11][5:4];
                end else if(index_q[c][2]+16'd1<descriptor[c][7])begin
                  index_q[c][0]<=0;index_q[c][1]<=0;index_q[c][2]<=index_q[c][2]+1;
                  cursor[c]<=advance2[15:0];
                  axis_base[c][1]<=advance2[15:0];axis_base[c][2]<=advance2[15:0];
                  cursor_overflow_q[c]<=axis_overflow_q[c][2]||(advance2[16]!=advance2[15]);
                  axis_overflow_q[c][1]<=axis_overflow_q[c][2]||(advance2[16]!=advance2[15]);
                  axis_overflow_q[c][2]<=axis_overflow_q[c][2]||(advance2[16]!=advance2[15]);
                  reg_cursor[c]<=reg_base[c][2]+descriptor[c][11][7:6];
                  reg_base[c][1]<=reg_base[c][2]+descriptor[c][11][7:6];reg_base[c][2]<=reg_base[c][2]+descriptor[c][11][7:6];
                end else if(descriptor[c][1][8])begin
                  cursor[c]<=descriptor[c][0];reg_cursor[c]<=descriptor[c][11][1:0];
                  cursor_overflow_q[c]<=0;axis_overflow_q[c]<=0;
                  for(integer a=0;a<3;a++)begin
                    index_q[c][a]<=0;reg_base[c][a]<=descriptor[c][11][1:0];
                  end
                  for(integer a=1;a<3;a++)axis_base[c][a]<=descriptor[c][0];
                end else ended_q[c]<=1;
              end
            end
          end
        end
        // Exact word invalidation retains unrelated activation/bias reuse.
        // A simultaneous fill of that word is invalidated with priority too.
        if(invalidate_i&&((cache_valid[p][invalidate_addr_i[2+:CACHE_BITS]]&&
            cache_tag[p][invalidate_addr_i[3:2]][cache_row(invalidate_addr_i)]==invalidate_addr_i[13:2+CACHE_BITS])||
            (waiting_q[p]&&rvalid_i[p]&&waiting_addr_q[p][13:2]==invalidate_addr_i[13:2])))
          cache_valid[p][invalidate_addr_i[2+:CACHE_BITS]]<=0;
        for(integer q=0;q<2;q++)if(req_o[q]&&we_o[q]&&gnt_i[q]&&
            ((cache_valid[p][addr_o[q][2+:CACHE_BITS]]&&cache_tag[p][addr_o[q][3:2]][cache_row(addr_o[q])]==addr_o[q][13:2+CACHE_BITS])||
             (waiting_q[p]&&rvalid_i[p]&&waiting_addr_q[p][13:2]==addr_o[q][13:2])))
          cache_valid[p][addr_o[q][2+:CACHE_BITS]]<=0;
      end
      // Dispatch has priority over retiring the old tile in a fused exchange.
      // Deferred mode reserves one four-value input buffer per request port.
      // FULL/store remain available through NEXT, without an extra tile RAM.
      if(start_allowed&&defer_i&&((contexts_i[0]&&contexts_i[2])||(contexts_i[1]&&contexts_i[3])))error_o<=1;
      if(start_allowed&&(!defer_i||!((contexts_i[0]&&contexts_i[2])||(contexts_i[1]&&contexts_i[3]))))begin
        row_mask_q<=row_mask_i;pending_q<=0;
        for(integer p=0;p<2;p++)if(contexts_i[p]||contexts_i[p+2])begin
          // Dispatch directly on acceptance: no extra pending stage for the
          // common one-context-per-port case. Same-port second context queues.
          active_q[p]<=1;selected_hi_q[p]<=!contexts_i[p];deferred_q[p]<=defer_i;
          group_q[p]<=0;gathered_q[p]<=0;stored_q[p]<=0;
          if(contexts_i[p]&&contexts_i[p+2])pending_q[p+2]<=1;
        end
      end
    end
  end
  initial if(CACHE_WORDS<4||CACHE_WORDS>64||(CACHE_WORDS&(CACHE_WORDS-1)))$fatal(1,"CACHE_WORDS must be 4..64 power of two");
endmodule
