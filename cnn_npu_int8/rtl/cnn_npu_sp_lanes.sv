`timescale 1ns/1ps
`default_nettype none

// Multi-lane single-port SRAM CNN engine.
//
// Descriptor flag bit2 selects weights packed as [oc/4][term][oc%4]. One
// 32-bit read supplies four signed INT8 lane weights. Legacy OIHW weights
// remain supported through serial prefetch into the same lane registers.
// All active accumulators perform a MAC on the same clock edge. Parameters
// are cached for an output-channel group; activation words have a one-entry
// cache. The first weight read overlaps activation response capture.
module cnn_npu_sp_lanes #(
    parameter integer LANES          = 4,
    parameter integer SRAM_BYTES     = 8192,
    parameter integer MAX_LAYERS     = 8,
    parameter integer DEFAULT_QMAX   = 127,
    parameter integer SHARED_SRAM    = 1,
    parameter integer MEM_BACKEND    = 1,
    parameter MEM_INIT_FILE          = ""
) (
    input  wire         clka,
    input  wire         rst_ni,
    input  wire         ena,
    input  wire         wea,
    input  wire [3:0]   be_i,
    input  wire [13:0]  addra,
    input  wire [31:0]  dina,
    output logic [31:0] douta,
    output logic        irq_o
);
  localparam integer LOCAL_BASE_WORD = 14'h1000;
  localparam integer LOCAL_WORDS = SRAM_BYTES / 4;
  localparam integer DESC_BYTES = 36;
  localparam logic [31:0] HOST_BUSY_ERROR = 32'hdead_b001;
  localparam integer REG_CONTROL=0, REG_STATUS=1, REG_IN_BASE=2,
                     REG_OUT_BASE=3, REG_DESC_BASE=4, REG_LAYER_CFG=5,
                     REG_CYCLE=6, REG_ERROR=7;
  localparam logic [7:0] FLAG_FC=8'h01, FLAG_RELU=8'h02, FLAG_PACK4=8'h04;

  typedef enum logic [5:0] {
    S_IDLE, S_DESC_REQ, S_DESC_WAIT, S_INIT,
    S_BIAS_REQ, S_BIAS_WAIT, S_TERM_PREP, S_TERM_SKIP,
    S_ACT_REQ, S_ACT_WAIT, S_WEIGHT_REQ, S_WEIGHT_WAIT, S_TERM_ADV,
    S_MULT_REQ, S_MULT_WAIT, S_SHIFT_REQ, S_SHIFT_WAIT,
    S_REQUANT_MUL, S_REQUANT_SHIFT, S_REQUANT_CLAMP,
    S_OUT_WRITE, S_OUT_ADV, S_DONE, S_ERROR, S_GROUP_INIT, S_MAC
  } state_t;
  state_t state_q;

  logic busy_q, done_q, error_q, irq_en_q, host_busy_error_seen_q;
  logic [31:0] douta_q;
  logic [31:0] in_base_reg, out_base_reg, desc_base_reg, cycle_q;
  logic [7:0] layer_count_q;
  localparam integer LANE_BITS=(LANES<2)?1:$clog2(LANES+1);
  logic [7:0] layer_q, oc_base_q, oy_q, ox_q, ci_q;
  logic [3:0] desc_index_q;
  logic [LANE_BITS-1:0] lane_q, lane_count_q;
  logic [1:0] ky_q, kx_q;

  logic [12:0] in_base_q, out_base_q, weight_base_q, bias_base_q;
  logic [12:0] mult_base_q, shift_base_q;
  logic [7:0] in_h_q, in_w_q, in_c_q, out_h_q, out_w_q, out_c_q;
  logic [7:0] stride_q, input_zp_q, output_zp_q, qmax_q;
  logic [7:0] flags_q;
  logic [31:0] desc_words_q [0:8];
  wire signed [31:0] acc_q [0:LANES-1];
  logic signed [31:0] bias_q [0:LANES-1];
  logic signed [31:0] multiplier_q [0:LANES-1];
  logic signed [7:0] weight_q [0:LANES-1];
  logic signed [63:0] product_q;
  integer scaled_q;
  integer quant_q;
  logic [7:0] shift_q [0:LANES-1];
  logic [7:0] output_q [0:LANES-1];
  logic [7:0] activation_q;
  logic act_cache_valid_q;
  logic [10:0] act_cache_addr_q;
  logic [31:0] act_cache_data_q;
  logic act_cache_hit;
  logic signed [8:0] centered_activation;
  wire group_init_enable,vector_mac_enable;

  logic eng_req, eng_we;
  logic [3:0] eng_be;
  logic [10:0] eng_addr;
  logic [31:0] eng_wdata, mem_rdata;
  logic bus_mem_req, bus_rd_pending_q, bus_local, host_busy_error_q;
  logic mem_req, mem_we;
  logic [3:0] mem_be;
  logic [10:0] mem_addr;
  logic [31:0] mem_wdata;
  integer bus_byte_addr, eng_byte_addr, act_addr_i, weight_addr_i;
  integer iy_i, ix_i, byte_lane_i;
  integer reset_i;
  integer vector_i;
  genvar mac_lane;

  initial begin
    if (!(LANES==1 || LANES==2 || LANES==4 || LANES==8))
      $fatal(1,"Single-port vector engine supports LANES=1/2/4/8");
    if (SRAM_BYTES!=8192) $fatal(1,"Single-port macro is 2048x32 (8192 bytes)");
  end

  function automatic [7:0] byte_of(input logic [31:0] word, input integer lane);
    byte_of = word[lane*8 +: 8];
  endfunction
  function automatic integer clamp_i(input integer x, input integer lo, input integer hi);
    if (x < lo) clamp_i=lo; else if (x > hi) clamp_i=hi; else clamp_i=x;
  endfunction
  function automatic integer round_shift(input logic signed [63:0] x, input integer s);
    logic signed [63:0] half;
    if (s <= 0) round_shift=x;
    else begin half=64'sd1 <<< (s-1); round_shift=(x+half)>>>s; end
  endfunction
  function automatic logic range_valid(input integer base, input integer bytes);
    range_valid = (base >= 0) && (bytes >= 0) &&
                  (base <= SRAM_BYTES) && (bytes <= SRAM_BYTES - base);
  endfunction
  function automatic logic descriptor_valid_words(
      input logic [31:0] w0, input logic [31:0] w1,
      input logic [31:0] w2, input logic [31:0] w3,
      input logic [31:0] w4, input logic [31:0] w5,
      input logic [31:0] w6, input logic [31:0] w7,
      input logic [31:0] w8);
    integer ib, ob, wb, bb, mb, sb;
    integer ih, iw, ic, oc, oh, ow, stride, flags;
    integer in_bytes, out_bytes, weight_bytes;
    logic valid;
    begin
      ib=w0; ob=w1; wb=w2; bb=w3; mb=w4; sb=w5;
      ih=w6[7:0]; iw=w6[15:8]; ic=w6[23:16]; oc=w6[31:24];
      oh=w7[7:0]; ow=w7[15:8]; stride=w7[23:16]; flags=w7[31:24];
      valid = (ih > 0) && (iw > 0) && (ic > 0) && (oc > 0) &&
              (oh > 0) && (ow > 0) && (stride > 0) &&
              ((flags & ~8'h07) == 0);
      if (flags & FLAG_FC) begin
        valid = valid && (ih == 1) && (iw == 1) && (oh == 1) && (ow == 1);
        in_bytes=ic; out_bytes=oc; weight_bytes=oc*ic;
      end else begin
        in_bytes=ih*iw*ic; out_bytes=oh*ow*oc; weight_bytes=oc*ic*9;
      end
      if (flags & FLAG_PACK4) begin
        weight_bytes=((oc+3)/4)*4*ic*((flags&FLAG_FC)?1:9);
        valid=valid && ((wb&3)==0);
      end
      valid = valid && range_valid(ib,in_bytes) && range_valid(ob,out_bytes) &&
              range_valid(wb,weight_bytes) && range_valid(bb,oc*4) &&
              range_valid(mb,oc*4) && range_valid(sb,oc);
      descriptor_valid_words = valid;
    end
  endfunction

  assign bus_local = (addra >= LOCAL_BASE_WORD) &&
                     (addra < LOCAL_BASE_WORD + LOCAL_WORDS);
  assign bus_byte_addr = (addra - LOCAL_BASE_WORD) * 4;
  assign irq_o = done_q && irq_en_q;
  assign act_cache_hit = act_cache_valid_q && (act_cache_addr_q == (act_addr_i>>2));
  assign centered_activation = $signed({1'b0,activation_q}) - $signed({1'b0,input_zp_q[7:0]});
  assign group_init_enable = (state_q==S_GROUP_INIT);
  assign vector_mac_enable = (state_q==S_MAC);
  generate
    for (mac_lane=0;mac_lane<LANES;mac_lane=mac_lane+1) begin : g_mac
      cnn_npu_lane_mac i_mac(.clk_i(clka),.rst_ni(rst_ni),
        .load_i(group_init_enable),
        .mac_i(vector_mac_enable&&(mac_lane<lane_count_q)),
        .activation_i(centered_activation),.weight_i(weight_q[mac_lane]),
        .bias_i(bias_q[mac_lane]),.acc_o(acc_q[mac_lane]));
    end
  endgenerate

  always_comb begin
    if (host_busy_error_q || (ena && bus_local && busy_q && !wea))
      douta = HOST_BUSY_ERROR;
    else if (bus_rd_pending_q)
      douta = mem_rdata;
    else
      douta = douta_q;
  end

  // During ACT_WAIT, capture the activation response while requesting the
  // first weight. Cache hits request that weight directly from ACT_REQ.
  always_comb begin
    eng_req=1'b0; eng_we=1'b0; eng_be=4'b1111; eng_byte_addr=0; eng_wdata=0;
    weight_addr_i=0;
    if (flags_q & FLAG_PACK4)
      weight_addr_i=weight_base_q+(((oc_base_q+lane_q)/4)*in_c_q*((flags_q&FLAG_FC)?1:9)
                    +ci_q*((flags_q&FLAG_FC)?1:9)+((flags_q&FLAG_FC)?0:(ky_q*3+kx_q)))*4;
    else if (flags_q & FLAG_FC)
      weight_addr_i=weight_base_q+(oc_base_q+lane_q)*in_c_q+ci_q;
    else
      weight_addr_i=weight_base_q+(((((oc_base_q+lane_q)*in_c_q)+ci_q)*3+ky_q)*3+kx_q);
    case (state_q)
      S_DESC_REQ: begin
        eng_req=1; eng_byte_addr=desc_base_reg+layer_q*DESC_BYTES+desc_index_q*4;
      end
      S_BIAS_REQ: begin
        eng_req=1; eng_byte_addr=bias_base_q+(oc_base_q+lane_q)*4;
      end
      S_ACT_REQ: begin
        eng_req=1; eng_byte_addr=act_cache_hit ? weight_addr_i : act_addr_i;
      end
      S_ACT_WAIT: begin eng_req=1; eng_byte_addr=weight_addr_i; end
      S_WEIGHT_REQ: begin
        eng_req=1;
        eng_byte_addr=weight_addr_i;
      end
      S_MULT_REQ: begin
        eng_req=1; eng_byte_addr=mult_base_q+(oc_base_q+lane_q)*4;
      end
      S_SHIFT_REQ: begin
        eng_req=1; eng_byte_addr=shift_base_q+oc_base_q+lane_q;
      end
      S_OUT_WRITE: begin
        eng_req=1; eng_we=1;
        eng_byte_addr=out_base_q+((flags_q&FLAG_FC)?(oc_base_q+lane_q):
                                   ((oc_base_q+lane_q)*out_h_q*out_w_q+oy_q*out_w_q+ox_q));
        byte_lane_i=eng_byte_addr & 3;
        eng_be=4'b0001 << byte_lane_i;
        eng_wdata={{24{1'b0}},output_q[lane_q]} << (byte_lane_i*8);
      end
      default: ;
    endcase
    eng_addr = eng_byte_addr >> 2;
  end

  always_comb begin
    bus_mem_req = ena && bus_local && !bus_rd_pending_q && !busy_q;
    mem_req = eng_req ? 1'b1 : bus_mem_req;
    mem_we  = eng_req ? eng_we : wea;
    mem_be  = eng_req ? eng_be : be_i;
    mem_addr= eng_req ? eng_addr : addra-LOCAL_BASE_WORD;
    mem_wdata=eng_req ? eng_wdata : dina;
  end

  generate
    if (MEM_BACKEND == 1) begin : g_fpga
      mynpu_sram_2048x32_fpga #(.INIT_FILE(MEM_INIT_FILE)) i_mem (
        .clk_i(clka), .req_i(mem_req), .we_i(mem_we), .be_i(mem_be),
        .addr_i(mem_addr), .wdata_i(mem_wdata), .rdata_o(mem_rdata));
    end else if (MEM_BACKEND == 2) begin : g_asic
      mynpu_sram_2048x32_asic i_mem (
        .clk_i(clka), .req_i(mem_req), .we_i(mem_we), .be_i(mem_be),
        .addr_i(mem_addr), .wdata_i(mem_wdata), .rdata_o(mem_rdata));
    end else begin : g_bad
      initial $fatal(1,"cnn_npu_sp_lanes requires MEM_BACKEND=1 FPGA or 2 ASIC");
      assign mem_rdata=32'd0;
    end
  endgenerate

  always @(posedge clka or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q<=S_IDLE; busy_q<=0; done_q<=0; error_q<=0; irq_en_q<=0;
      douta_q<=0; in_base_reg<=0; out_base_reg<=0; desc_base_reg<=0;
      layer_count_q<=MAX_LAYERS; cycle_q<=0; bus_rd_pending_q<=0;
      host_busy_error_q<=1'b0; host_busy_error_seen_q<=1'b0;
      layer_q<=0; desc_index_q<=0; oc_base_q<=0; lane_q<=0; lane_count_q<=0;
      oy_q<=0; ox_q<=0; ci_q<=0; ky_q<=0; kx_q<=0;
      activation_q<=0;
      in_base_q<=0;out_base_q<=0;weight_base_q<=0;bias_base_q<=0;mult_base_q<=0;shift_base_q<=0;
      in_h_q<=0;in_w_q<=0;in_c_q<=0;out_h_q<=0;out_w_q<=0;out_c_q<=0;
      stride_q<=0;input_zp_q<=0;output_zp_q<=0;qmax_q<=0;flags_q<=0;act_addr_i<=0;
      for (reset_i=0;reset_i<9;reset_i=reset_i+1) desc_words_q[reset_i]<=0;
      act_cache_valid_q<=0; act_cache_addr_q<=0; act_cache_data_q<=0;
      product_q<=0; scaled_q<=0;
      for (reset_i=0; reset_i<LANES; reset_i=reset_i+1) begin
        bias_q[reset_i]<=0; multiplier_q[reset_i]<=0;
        weight_q[reset_i]<=0; shift_q[reset_i]<=0; output_q[reset_i]<=0;
      end
    end else begin
      host_busy_error_q <= 1'b0;
      if (bus_rd_pending_q) begin
        douta_q <= mem_rdata;
        bus_rd_pending_q <= 1'b0;
      end else if (bus_mem_req && !wea) begin
        bus_rd_pending_q <= 1'b1;
      end else if (ena && bus_local && busy_q && !wea) begin
        host_busy_error_seen_q <= 1'b1;
        host_busy_error_q <= 1'b1;
      end else if (ena && !wea && !bus_local) begin
        case (addra)
          REG_CONTROL: douta_q <= {30'd0,irq_en_q,1'b0};
          REG_STATUS: douta_q <= {29'd0,error_q,done_q,busy_q};
          REG_IN_BASE: douta_q <= in_base_reg;
          REG_OUT_BASE: douta_q <= out_base_reg;
          REG_DESC_BASE: douta_q <= desc_base_reg;
          REG_LAYER_CFG: douta_q <= {24'd0,layer_count_q};
          REG_CYCLE: douta_q <= cycle_q;
          REG_ERROR: douta_q <= host_busy_error_seen_q ? HOST_BUSY_ERROR : {31'd0,error_q};
          default: douta_q <= 0;
        endcase
      end

      if (ena && wea && !bus_local) begin
        case (addra)
          REG_CONTROL: begin
            irq_en_q<=dina[1];
            if (dina[2]) begin
              done_q<=0; error_q<=0; host_busy_error_seen_q<=1'b0;
              if (!busy_q && (state_q == S_ERROR)) state_q<=S_IDLE;
            end
            if (dina[0] && !busy_q) begin
              done_q<=0;
              if (layer_count_q > MAX_LAYERS) begin
                busy_q<=0; error_q<=1; state_q<=S_ERROR;
              end else begin
                busy_q<=1; error_q<=0; cycle_q<=0; layer_q<=0;
                act_cache_valid_q<=0;
                desc_index_q<=0; oc_base_q<=0; lane_q<=0; state_q<=S_DESC_REQ;
              end
            end
          end
          REG_IN_BASE: in_base_reg<=dina;
          REG_OUT_BASE: out_base_reg<=dina;
          REG_DESC_BASE: desc_base_reg<=dina;
          REG_LAYER_CFG: layer_count_q <= (dina[7:0]==0)?MAX_LAYERS:dina[7:0];
          REG_ERROR: begin
            error_q<=0;
            if (!busy_q && (state_q == S_ERROR)) state_q<=S_IDLE;
          end
          default: ;
        endcase
      end else if (ena && wea && bus_local && busy_q) begin
        host_busy_error_seen_q <= 1'b1;
      end

      if (busy_q) cycle_q<=cycle_q+1'b1;

      case (state_q)
        S_IDLE: ;
        S_DESC_REQ: begin
          if (desc_base_reg > SRAM_BYTES)
            state_q<=S_ERROR;
          else if ((layer_count_q > MAX_LAYERS) ||
                   (layer_count_q*DESC_BYTES > SRAM_BYTES-desc_base_reg))
            state_q<=S_ERROR;
          else if (desc_base_reg + layer_q*DESC_BYTES + desc_index_q*4 + 3 > SRAM_BYTES)
            state_q<=S_ERROR;
          else state_q<=S_DESC_WAIT;
        end
        S_DESC_WAIT: begin
          desc_words_q[desc_index_q] <= mem_rdata;
          if (desc_index_q==8) state_q<=S_INIT;
          else begin desc_index_q<=desc_index_q+1; state_q<=S_DESC_REQ; end
        end
        S_INIT: begin
          if (!descriptor_valid_words(desc_words_q[0],desc_words_q[1],desc_words_q[2],
                                     desc_words_q[3],desc_words_q[4],desc_words_q[5],
                                     desc_words_q[6],desc_words_q[7],desc_words_q[8])) begin
            state_q<=S_ERROR;
          end else begin
            in_base_q<=desc_words_q[0]; out_base_q<=desc_words_q[1]; weight_base_q<=desc_words_q[2];
            bias_base_q<=desc_words_q[3]; mult_base_q<=desc_words_q[4]; shift_base_q<=desc_words_q[5];
            in_h_q<=desc_words_q[6][7:0]; in_w_q<=desc_words_q[6][15:8];
            in_c_q<=desc_words_q[6][23:16]; out_c_q<=desc_words_q[6][31:24];
            out_h_q<=desc_words_q[7][7:0]; out_w_q<=desc_words_q[7][15:8];
            stride_q<=desc_words_q[7][23:16]; flags_q<=desc_words_q[7][31:24];
            input_zp_q<=desc_words_q[8][7:0]; output_zp_q<=desc_words_q[8][15:8];
            qmax_q<=(desc_words_q[8][23:16]==0)?DEFAULT_QMAX:desc_words_q[8][23:16];
            lane_count_q <= (desc_words_q[6][31:24] < LANES) ?
                            desc_words_q[6][31:24] : LANES;
            act_cache_valid_q<=0;
            oc_base_q<=0; lane_q<=0; oy_q<=0; ox_q<=0; state_q<=S_BIAS_REQ;
          end
        end
        S_BIAS_REQ: state_q<=S_BIAS_WAIT;
        S_BIAS_WAIT: begin
          bias_q[lane_q] <= $signed(mem_rdata);
          state_q<=S_MULT_REQ;
        end
        S_GROUP_INIT: begin
          lane_q<=0; ci_q<=0; ky_q<=0; kx_q<=0; state_q<=S_TERM_PREP;
        end
        S_TERM_PREP: begin
          lane_q<=0;
          if (flags_q & FLAG_FC) begin
            act_addr_i=in_base_q+ci_q;
            state_q<=S_ACT_REQ;
          end else begin
            iy_i=oy_q*stride_q+ky_q-1; ix_i=ox_q*stride_q+kx_q-1;
            if ((iy_i<0)||(iy_i>=in_h_q)||(ix_i<0)||(ix_i>=in_w_q))
              state_q<=S_TERM_SKIP;
            else begin
              act_addr_i=in_base_q+ci_q*in_h_q*in_w_q+iy_i*in_w_q+ix_i;
              state_q<=S_ACT_REQ;
            end
          end
        end
        S_TERM_SKIP: state_q<=S_TERM_ADV;
        S_ACT_REQ: begin
          if (act_cache_hit) begin
            activation_q<=byte_of(act_cache_data_q,act_addr_i&3);
            state_q<=S_WEIGHT_WAIT;
          end else state_q<=S_ACT_WAIT;
        end
        S_ACT_WAIT: begin
          activation_q<=byte_of(mem_rdata,act_addr_i&3);
          act_cache_valid_q<=1; act_cache_addr_q<=act_addr_i>>2; act_cache_data_q<=mem_rdata;
          state_q<=S_WEIGHT_WAIT;
        end
        S_WEIGHT_REQ: state_q<=S_WEIGHT_WAIT;
        S_WEIGHT_WAIT: begin
          if (flags_q & FLAG_PACK4) begin
            for (vector_i=0;vector_i<LANES;vector_i=vector_i+1)
              if (vector_i>=lane_q && vector_i<lane_q+4 && vector_i<lane_count_q)
                weight_q[vector_i]<=$signed(byte_of(mem_rdata,(oc_base_q+vector_i)&3));
            if (lane_q+4 < lane_count_q) begin
              lane_q<=lane_q+4; state_q<=S_WEIGHT_REQ;
            end else begin lane_q<=0; state_q<=S_MAC; end
          end else begin
            weight_q[lane_q]<=$signed(byte_of(mem_rdata,weight_addr_i&3));
            if (lane_q+1 < lane_count_q) begin
            lane_q<=lane_q+1; state_q<=S_WEIGHT_REQ;
            end else begin lane_q<=0; state_q<=S_MAC; end
          end
        end
        S_MAC, S_TERM_ADV: begin
          if (flags_q & FLAG_FC) begin
            if (ci_q==in_c_q-1) begin lane_q<=0; state_q<=S_REQUANT_MUL; end
            else begin ci_q<=ci_q+1; state_q<=S_TERM_PREP; end
          end else if (kx_q!=2) begin
            kx_q<=kx_q+1; state_q<=S_TERM_PREP;
          end else if (ky_q!=2) begin
            kx_q<=0; ky_q<=ky_q+1; state_q<=S_TERM_PREP;
          end else if (ci_q!=in_c_q-1) begin
            kx_q<=0; ky_q<=0; ci_q<=ci_q+1; state_q<=S_TERM_PREP;
          end else begin lane_q<=0; state_q<=S_REQUANT_MUL; end
        end
        S_MULT_REQ: state_q<=S_MULT_WAIT;
        S_MULT_WAIT: begin
          multiplier_q[lane_q]<=$signed(mem_rdata); state_q<=S_SHIFT_REQ;
        end
        S_SHIFT_REQ: state_q<=S_SHIFT_WAIT;
        S_SHIFT_WAIT: begin
          if (byte_of(mem_rdata,(shift_base_q+oc_base_q+lane_q)&3) > 63)
            state_q<=S_ERROR;
          else begin
            shift_q[lane_q]<=byte_of(mem_rdata,(shift_base_q+oc_base_q+lane_q)&3);
            if (lane_q+1<lane_count_q) begin lane_q<=lane_q+1; state_q<=S_BIAS_REQ; end
            else begin lane_q<=0; state_q<=S_GROUP_INIT; end
          end
        end
        S_REQUANT_MUL: begin
          product_q <= $signed(acc_q[lane_q]) * $signed(multiplier_q[lane_q]);
          state_q <= S_REQUANT_SHIFT;
        end
        S_REQUANT_SHIFT: begin
          scaled_q <= round_shift(product_q,shift_q[lane_q]);
          state_q <= S_REQUANT_CLAMP;
        end
        S_REQUANT_CLAMP: begin
          quant_q = scaled_q + output_zp_q;
          if ((flags_q&FLAG_RELU)&&(quant_q<$signed({1'b0,output_zp_q}))) quant_q=output_zp_q;
          output_q[lane_q] <= clamp_i(quant_q,0,qmax_q);
          if (lane_q+1 < lane_count_q) begin
            lane_q<=lane_q+1; state_q<=S_REQUANT_MUL;
          end else begin
            lane_q<=0; state_q<=S_OUT_WRITE;
          end
        end
        S_OUT_WRITE: begin act_cache_valid_q<=0; state_q<=S_OUT_ADV; end
        S_OUT_ADV: begin
          if (lane_q+1 < lane_count_q) begin
            lane_q<=lane_q+1; state_q<=S_OUT_WRITE;
          end else if (!(flags_q&FLAG_FC) && ox_q+1<out_w_q) begin
            ox_q<=ox_q+1; lane_q<=0; state_q<=S_GROUP_INIT;
          end else if (!(flags_q&FLAG_FC) && oy_q+1<out_h_q) begin
            oy_q<=oy_q+1; ox_q<=0; lane_q<=0; state_q<=S_GROUP_INIT;
          end else if (oc_base_q+LANES < out_c_q) begin
            oc_base_q<=oc_base_q+LANES;
            lane_q<=0; oy_q<=0; ox_q<=0;
            lane_count_q <= ((out_c_q-(oc_base_q+LANES)) < LANES) ?
                             (out_c_q-(oc_base_q+LANES)) : LANES;
            state_q<=S_BIAS_REQ;
          end else if (layer_q+1>=layer_count_q) begin
            busy_q<=0; done_q<=1; state_q<=S_DONE;
          end else begin
            layer_q<=layer_q+1; desc_index_q<=0; state_q<=S_DESC_REQ;
          end
        end
        S_DONE: ;
        S_ERROR: begin
          // START was handled by the register decoder above. Preserve its
          // BUSY/error updates, including combined CLEAR+START recovery.
          if (!(ena && wea && !bus_local && !busy_q &&
                addra==REG_CONTROL && dina[0])) begin
            busy_q<=0;
            if (!(ena && wea && !bus_local &&
                  ((addra == REG_CONTROL && dina[2]) || (addra == REG_ERROR))))
              error_q<=1;
          end
        end
        default: state_q<=S_ERROR;
      endcase
    end
  end
endmodule
`default_nettype wire
