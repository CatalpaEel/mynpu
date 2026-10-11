`timescale 1ns/1ps

// Small descriptor-driven INT8 CNN engine.
//
// The bus is intentionally the same memory-like request used by lab3.  The
// local SRAM is byte-addressed internally and exposed as packed 32-bit words.
// A layer descriptor is 9 words (36 bytes):
//   0..5: input, output, weight, bias, multiplier and shift byte offsets
//   6: input H/W/Cin/Cout
//   7: output H/W/stride/flags
//   8: input_zp/output_zp/qmax/reserved
// flags bit0 selects FC mode; bit1 enables ReLU.
module cnn_npu_top #(
    parameter integer LANES           = 16,
    parameter integer SRAM_BYTES      = 16*1024,
    parameter integer LOCAL_BASE_WORD= 14'h1000,
    parameter integer MAX_LAYERS      = 8,
    parameter integer DEFAULT_QMAX    = 127,
    parameter integer SHARED_SRAM     = 1,
    parameter MEM_INIT_FILE           = ""
) (
    input  logic        clka,
    input  logic        rst_ni,
    input  logic        ena,
    input  logic        wea,
    input  logic [3:0]  be_i,
    input  logic [13:0] addra,
    input  logic [31:0] dina,
    output logic [31:0] douta,
    output logic        irq_o
);

  localparam integer LOCAL_WORDS = SRAM_BYTES / 4;
  localparam integer DESC_BYTES  = 36;
  localparam integer REG_CONTROL = 0;
  localparam integer REG_STATUS  = 1;
  localparam integer REG_IN_BASE = 2;
  localparam integer REG_OUT_BASE= 3;
  localparam integer REG_DESC_BASE=4;
  localparam integer REG_LAYER_CFG=5;
  localparam integer REG_CYCLE   = 6;
  localparam integer REG_ERROR   = 7;
  localparam logic [7:0] FLAG_FC=8'h01;
  localparam logic [7:0] FLAG_RELU=8'h02;

  logic [7:0] mem [0:SRAM_BYTES-1];
  initial if (MEM_INIT_FILE != "") $readmemh(MEM_INIT_FILE, mem);

  function automatic [7:0] rd8(input integer a);
    if ((a >= 0) && (a < SRAM_BYTES)) rd8 = mem[a]; else rd8 = 8'd0;
  endfunction
  function automatic [31:0] rd32(input integer a);
    if ((a >= 0) && ((a+3) < SRAM_BYTES))
      rd32 = {mem[a+3],mem[a+2],mem[a+1],mem[a]};
    else rd32 = 32'd0;
  endfunction
  function automatic logic range_valid(input integer base, input integer bytes);
    range_valid = (base >= 0) && (bytes >= 0) &&
                  (base <= SRAM_BYTES) && (bytes <= SRAM_BYTES - base);
  endfunction
  function automatic logic descriptor_valid(input integer base);
    integer ib, ob, wb, bb, mb, sb;
    integer ih, iw, ic, oc, oh, ow, stride, flags;
    integer in_bytes, out_bytes, weight_bytes, i;
    logic valid;
    begin
      ib = rd32(base+0); ob = rd32(base+4); wb = rd32(base+8);
      bb = rd32(base+12); mb = rd32(base+16); sb = rd32(base+20);
      ih = rd8(base+24); iw = rd8(base+25); ic = rd8(base+26); oc = rd8(base+27);
      oh = rd8(base+28); ow = rd8(base+29); stride = rd8(base+30);
      flags = rd8(base+31);
      valid = (ih > 0) && (iw > 0) && (ic > 0) && (oc > 0) &&
              (oh > 0) && (ow > 0) && (stride > 0) &&
              ((flags & ~8'h03) == 0);
      if (flags & FLAG_FC) begin
        valid = valid && (ih == 1) && (iw == 1) && (oh == 1) && (ow == 1);
        in_bytes = ic;
        out_bytes = oc;
        weight_bytes = oc * ic;
      end else begin
        in_bytes = ih * iw * ic;
        out_bytes = oh * ow * oc;
        weight_bytes = oc * ic * 9;
      end
      valid = valid && range_valid(ib, in_bytes) && range_valid(ob, out_bytes) &&
              range_valid(wb, weight_bytes) && range_valid(bb, oc*4) &&
              range_valid(mb, oc*4) && range_valid(sb, oc);
      // round_shift uses a 64-bit intermediate; reject an impossible shift
      // before it can create an undefined variable shift in simulation/RTL.
      for (i=0; i<oc; i=i+1)
        valid = valid && (rd8(sb+i) <= 63);
      descriptor_valid = valid;
    end
  endfunction
  function automatic integer clamp_i(input integer x, input integer lo, input integer hi);
    if (x < lo) clamp_i=lo; else if (x > hi) clamp_i=hi; else clamp_i=x;
  endfunction
  function automatic integer rshift_round(input logic signed [63:0] x, input integer s);
    logic signed [63:0] off;
    if (s <= 0) rshift_round=x;
    else begin
      off = 64'sd1 <<< (s-1);
      // Fixed-point rounding: nearest, with exact ties toward +infinity.
      // This is the RTL arithmetic contract, not bit-exact FBGEMM rounding.
      rshift_round=(x+off)>>>s;
    end
  endfunction

  typedef enum logic [3:0] {IDLE,LOAD_DESC,INIT_BLOCK,MAC,REQUANT,WRITE,DONE,ERROR} state_t;
  state_t state_q;
  logic busy_q, done_q, error_q, irq_en_q;
  logic [31:0] in_base_reg, out_base_reg, desc_base_reg, cycle_q;
  logic [7:0] layer_count_q;
  integer layer_q, oy_q, ox_q, oc_base_q, ky_q, kx_q, ci_q;

  integer in_base_q, out_base_q, weight_base_q, bias_base_q;
  integer mult_base_q, shift_base_q;
  integer in_h_q, in_w_q, in_c_q, out_h_q, out_w_q, out_c_q;
  integer stride_q, input_zp_q, output_zp_q, qmax_q;
  logic [7:0] flags_q;
  logic signed [31:0] acc_q [0:LANES-1];
  logic [7:0] out_q [0:LANES-1];

  integer l, oc, desc_addr, act_addr, weight_addr, iy, ix;
  integer a_u, a_centered, w_s, product, mult_i, shift_i, scaled_i, quant_i;
  logic signed [63:0] product64;
  integer bus_byte_addr;
  logic bus_local;

  always_comb begin
    bus_byte_addr = (addra - LOCAL_BASE_WORD) * 4;
    bus_local = (addra >= LOCAL_BASE_WORD) &&
                (addra < LOCAL_BASE_WORD + LOCAL_WORDS);
  end
  assign irq_o = done_q && irq_en_q;

  always_ff @(posedge clka or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= IDLE;
      busy_q        <= 1'b0;
      done_q        <= 1'b0;
      error_q       <= 1'b0;
      irq_en_q      <= 1'b0;
      in_base_reg   <= 32'd0;
      out_base_reg  <= 32'd0;
      desc_base_reg <= 32'd0;
      layer_count_q <= MAX_LAYERS;
      cycle_q       <= 32'd0;
      douta         <= 32'd0;
      layer_q       <= 0;
      oy_q          <= 0;
      ox_q          <= 0;
      oc_base_q     <= 0;
      ky_q          <= 0;
      kx_q          <= 0;
      ci_q          <= 0;
    end else begin
      // Lab3's axi2mem has a one-cycle read latency.  CPU writes while busy
      // are ignored with SHARED_SRAM=1. This multi-access functional array
      // still needs a physical SRAM controller/banking implementation.
      if (ena && wea) begin
        if (bus_local) begin
          if (!SHARED_SRAM || !busy_q) begin
            if (be_i[0]) mem[bus_byte_addr+0] <= dina[7:0];
            if (be_i[1]) mem[bus_byte_addr+1] <= dina[15:8];
            if (be_i[2]) mem[bus_byte_addr+2] <= dina[23:16];
            if (be_i[3]) mem[bus_byte_addr+3] <= dina[31:24];
          end
        end else begin
          case (addra)
            REG_CONTROL: begin
              irq_en_q <= dina[1];
              if (dina[2]) begin
                done_q<=1'b0; error_q<=1'b0;
                if (!busy_q && (state_q == ERROR)) state_q<=IDLE;
              end
              if (dina[0] && !busy_q) begin
                done_q<=1'b0;
                if (layer_count_q > MAX_LAYERS) begin
                  busy_q<=1'b0; error_q<=1'b1; state_q<=ERROR;
                end else begin
                  busy_q<=1'b1; error_q<=1'b0;
                  cycle_q<=0; layer_q<=0; state_q<=LOAD_DESC;
                end
              end
            end
            REG_IN_BASE:    in_base_reg   <= dina;
            REG_OUT_BASE:   out_base_reg  <= dina;
            REG_DESC_BASE:  desc_base_reg <= dina;
            REG_LAYER_CFG:  layer_count_q <= (dina[7:0]==0) ? MAX_LAYERS : dina[7:0];
            REG_ERROR: begin
              error_q <= 1'b0;
              if (!busy_q && (state_q == ERROR)) state_q<=IDLE;
            end
            default: ;
          endcase
        end
      end
      if (ena && !wea) begin
        douta <= 32'd0;
        if (bus_local) douta <= rd32(bus_byte_addr);
        else case (addra)
          REG_CONTROL: douta <= {30'd0,irq_en_q,1'b0};
          REG_STATUS:  douta <= {29'd0,error_q,done_q,busy_q};
          REG_IN_BASE: douta <= in_base_reg;
          REG_OUT_BASE:douta <= out_base_reg;
          REG_DESC_BASE:douta <= desc_base_reg;
          REG_LAYER_CFG:douta <= {24'd0,layer_count_q};
          REG_CYCLE:   douta <= cycle_q;
          REG_ERROR:   douta <= {31'd0,error_q};
          default:     douta <= 32'd0;
        endcase
      end

      if (busy_q) cycle_q <= cycle_q + 1'b1;

      case (state_q)
        IDLE: ;
        LOAD_DESC: begin
          if (desc_base_reg > SRAM_BYTES) begin
            busy_q<=1'b0; error_q<=1'b1; state_q<=ERROR;
          end else if ((layer_count_q > MAX_LAYERS) ||
                       (layer_count_q*DESC_BYTES > SRAM_BYTES-desc_base_reg)) begin
            busy_q<=1'b0; error_q<=1'b1; state_q<=ERROR;
          end else if (layer_q >= layer_count_q) begin
            busy_q<=1'b0; done_q<=1'b1; state_q<=DONE;
          end else if (!descriptor_valid(desc_base_reg + layer_q*DESC_BYTES)) begin
            busy_q<=1'b0; error_q<=1'b1; state_q<=ERROR;
          end else begin
            desc_addr = desc_base_reg + layer_q*DESC_BYTES;
            in_base_q    <= rd32(desc_addr+0);
            out_base_q   <= rd32(desc_addr+4);
            weight_base_q<= rd32(desc_addr+8);
            bias_base_q  <= rd32(desc_addr+12);
            mult_base_q  <= rd32(desc_addr+16);
            shift_base_q <= rd32(desc_addr+20);
            in_h_q       <= rd8(desc_addr+24);
            in_w_q       <= rd8(desc_addr+25);
            in_c_q       <= rd8(desc_addr+26);
            out_c_q      <= rd8(desc_addr+27);
            out_h_q      <= rd8(desc_addr+28);
            out_w_q      <= rd8(desc_addr+29);
            stride_q     <= rd8(desc_addr+30);
            flags_q      <= rd8(desc_addr+31);
            input_zp_q   <= rd8(desc_addr+32);
            output_zp_q  <= rd8(desc_addr+33);
            qmax_q       <= (rd8(desc_addr+34)==0) ? DEFAULT_QMAX : rd8(desc_addr+34);
            oy_q<=0; ox_q<=0; oc_base_q<=0; state_q<=INIT_BLOCK;
          end
        end
        INIT_BLOCK: begin
          for (l=0;l<LANES;l=l+1) begin
            oc=oc_base_q+l;
            if (oc<out_c_q) acc_q[l]<=$signed(rd32(bias_base_q+oc*4));
            else acc_q[l]<=0;
          end
          ky_q<=0; kx_q<=0; ci_q<=0; state_q<=MAC;
        end
        MAC: begin
          for (l=0;l<LANES;l=l+1) begin
            oc=oc_base_q+l;
            if (oc<out_c_q) begin
              if (flags_q & FLAG_FC) begin
                act_addr=in_base_q+ci_q;
                weight_addr=weight_base_q+oc*in_c_q+ci_q;
              end else begin
                iy=oy_q*stride_q+ky_q-1;
                ix=ox_q*stride_q+kx_q-1;
                if ((iy<0)||(iy>=in_h_q)||(ix<0)||(ix>=in_w_q)) act_addr=-1;
                else act_addr=in_base_q+(ci_q*in_h_q*in_w_q)+iy*in_w_q+ix;
                weight_addr=weight_base_q+((((oc*in_c_q)+ci_q)*3+ky_q)*3+kx_q);
              end
              if (act_addr<0) a_u=input_zp_q; else a_u=rd8(act_addr);
              a_centered=a_u-input_zp_q;
              w_s=$signed(rd8(weight_addr));
              product=a_centered*w_s;
              acc_q[l]<=acc_q[l]+product;
            end
          end
          if (flags_q & FLAG_FC) begin
            if (ci_q==in_c_q-1) state_q<=REQUANT; else ci_q<=ci_q+1;
          end else if (kx_q!=2) kx_q<=kx_q+1;
          else if (ky_q!=2) begin kx_q<=0; ky_q<=ky_q+1; end
          else if (ci_q!=in_c_q-1) begin kx_q<=0; ky_q<=0; ci_q<=ci_q+1; end
          else state_q<=REQUANT;
        end
        REQUANT: begin
          for (l=0;l<LANES;l=l+1) begin
            oc=oc_base_q+l;
            if (oc<out_c_q) begin
              mult_i=$signed(rd32(mult_base_q+oc*4));
              shift_i=rd8(shift_base_q+oc);
              product64=$signed(acc_q[l])*$signed(mult_i);
              scaled_i=rshift_round(product64,shift_i);
              quant_i=scaled_i+output_zp_q;
              if ((flags_q & FLAG_RELU) && (quant_i<output_zp_q)) quant_i=output_zp_q;
              out_q[l]<=clamp_i(quant_i,0,qmax_q);
            end else out_q[l]<=0;
          end
          state_q<=WRITE;
        end
        WRITE: begin
          for (l=0;l<LANES;l=l+1) begin
            oc=oc_base_q+l;
            if (oc<out_c_q) begin
              if (flags_q & FLAG_FC) act_addr=out_base_q+oc;
              else act_addr=out_base_q+oc*out_h_q*out_w_q+oy_q*out_w_q+ox_q;
              if ((act_addr>=0)&&(act_addr<SRAM_BYTES)) mem[act_addr]<=out_q[l];
            end
          end
          if (oc_base_q+LANES<out_c_q) begin
            oc_base_q<=oc_base_q+LANES; state_q<=INIT_BLOCK;
          end else if (flags_q & FLAG_FC) begin
            if (layer_q+1>=layer_count_q) begin busy_q<=0; done_q<=1; state_q<=DONE; end
            else begin layer_q<=layer_q+1; state_q<=LOAD_DESC; end
          end else if (ox_q+1<out_w_q) begin
            ox_q<=ox_q+1; oc_base_q<=0; state_q<=INIT_BLOCK;
          end else if (oy_q+1<out_h_q) begin
            oy_q<=oy_q+1; ox_q<=0; oc_base_q<=0; state_q<=INIT_BLOCK;
          end else if (layer_q+1>=layer_count_q) begin
            busy_q<=0; done_q<=1; state_q<=DONE;
          end else begin layer_q<=layer_q+1; state_q<=LOAD_DESC; end
        end
        DONE: ;
        ERROR: begin
          busy_q<=0;
          // A clear arriving while in ERROR must win over the sticky error
          // assignment; otherwise the state machine can never recover.
          if (!(ena && wea && !bus_local &&
                ((addra == REG_CONTROL && dina[2]) || (addra == REG_ERROR))))
            error_q<=1;
        end
        default: state_q<=ERROR;
      endcase
    end
  end
endmodule
