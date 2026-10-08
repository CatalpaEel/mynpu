// Three DMA channels at MMIO +0x300/+0x400/+0x500.
module npu_dma_regs (
  input logic clk_i, rst_ni, req_i, we_i,
  input logic [11:0] addr_i,
  input logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic error_o,
  output logic [2:0] start_o, abort_o, irq_o,
  output logic [2:0][31:0] src_o, dst_o, row_bytes_o, rows_o,
  output logic [2:0][31:0] src_stride_o, dst_stride_o, mode_o, fill_o, timeout_o,
  input logic [2:0] busy_i, done_i, fault_i,
  input logic [2:0][3:0] fault_code_i,
  input logic [2:0][31:0] bytes_done_i, cycles_i
);
  logic [2:0] done_q, error_q, occupied, descriptor_ok;
  logic [2:0][3:0] error_code_q;
  logic known, writable, page_valid;
  logic [1:0] channel;
  function automatic logic [31:0] span(input logic [31:0] bytes, rows, stride);
    logic [11:0] last_row;
    logic [25:0] row_offset;
    last_row = rows[11:0] - 12'd1;
    row_offset = last_row * stride[13:0];
    return {6'b0,row_offset} + bytes;
  endfunction
  function automatic logic range_ok(input logic [31:0] base, bytes, rows, stride);
    return base[31:13] == 19'h40000 && base[1:0] == 0
      && bytes >= 1 && bytes <= 8192 && rows >= 1 && rows <= 2048
      && stride <= 8192 && stride[1:0] == 0
      && (stride == 0 || rows == 1 || stride >= ((bytes+3) & 32'hfffffffc))
      && ({19'b0,base[12:0]} + span(bytes,rows,stride)) <= 8192;
  endfunction
  function automatic logic copy_alias_ok(input logic [31:0] src,dst,bytes,rows,ss,ds);
    return (src == dst && ss == ds)
      || ({1'b0,src} + {1'b0,span(bytes,rows,ss)}) <= {1'b0,dst}
      || ({1'b0,dst} + {1'b0,span(bytes,rows,ds)}) <= {1'b0,src};
  endfunction
  assign occupied = busy_i | start_o;
  assign irq_o = done_q;
  always_comb begin
    for (int c=0;c<3;c++) begin
      descriptor_ok[c] = (c == 0 ? mode_o[c] == 0 : c == 1 ? mode_o[c] == 1 : mode_o[c] == 2 || mode_o[c] == 3)
        && row_bytes_o[c] >= 1 && row_bytes_o[c] <= 8192 && rows_o[c] >= 1 && rows_o[c] <= 2048;
      if (c != 0 && mode_o[c] != 3)
        descriptor_ok[c] &= range_ok(src_o[c],row_bytes_o[c],rows_o[c],src_stride_o[c]);
      if (c != 1) begin
        descriptor_ok[c] &= range_ok(dst_o[c],row_bytes_o[c],rows_o[c],dst_stride_o[c])
          && (rows_o[c] == 1 || dst_stride_o[c] >= ((row_bytes_o[c]+3) & 32'hfffffffc));
      end
      if (c == 2 && mode_o[c] == 2)
        descriptor_ok[c] &= copy_alias_ok(src_o[c],dst_o[c],row_bytes_o[c],rows_o[c],src_stride_o[c],dst_stride_o[c]);
    end
    page_valid = 1;
    case(addr_i[11:8])
      4'h3: channel = 0;
      4'h4: channel = 1;
      4'h5: channel = 2;
      default: begin channel=0;page_valid=0;end
    endcase
    rdata_o=0;known=page_valid;writable=1;
    case(addr_i[7:0])
      8'h00: rdata_o=0;
      8'h04: begin rdata_o={29'b0,error_q[channel],done_q[channel],occupied[channel]};writable=0;end
      8'h08: rdata_o=src_o[channel];
      8'h0c: rdata_o=dst_o[channel];
      8'h10: rdata_o=row_bytes_o[channel];
      8'h14: rdata_o=rows_o[channel];
      8'h18: rdata_o=src_stride_o[channel];
      8'h1c: rdata_o=dst_stride_o[channel];
      8'h20: rdata_o=mode_o[channel];
      8'h24: rdata_o=fill_o[channel];
      8'h28: begin rdata_o=bytes_done_i[channel];writable=0;end
      8'h2c: begin rdata_o=cycles_i[channel];writable=0;end
      8'h30: begin rdata_o={28'b0,error_code_q[channel]};writable=0;end
      8'h34: rdata_o=timeout_o[channel];
      default: begin rdata_o=32'hdeadbeef;known=0;writable=0;end
    endcase
    error_o=!known || (we_i && !writable)
      || (we_i && addr_i[7:0]!=0 && occupied[channel]);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_o <= '0; dst_o <= '0; row_bytes_o <= '0; rows_o <= '0;
      src_stride_o <= '0; dst_stride_o <= '0; fill_o <= '0; timeout_o <= '0;
      mode_o[0] <= 0; mode_o[1] <= 1; mode_o[2] <= 2;
      start_o <= 0; abort_o <= 0; done_q <= 0; error_q <= 0; error_code_q <= 0;
    end else begin
      start_o<=0;abort_o<=0;
      for(int c=0;c<3;c++) begin
        if(done_i[c]) done_q[c]<=1;
        if(fault_i[c]) begin error_q[c]<=1;error_code_q[c]<=fault_code_i[c];end
      end
      if(req_i && we_i && page_valid) begin
        if(addr_i[7:0]!=0 && occupied[channel]) begin
          error_q[channel]<=1;error_code_q[channel]<=2;
        end
        if(!error_o) case(addr_i[7:0])
          8'h00: begin
            if(occupied[channel]) begin
              if(wdata_i[2]) abort_o[channel]<=1;
              if(wdata_i[1:0]!=0) begin error_q[channel]<=1;error_code_q[channel]<=2;end
            end else begin
              if(wdata_i[1]) begin done_q[channel]<=0;error_q[channel]<=0;error_code_q[channel]<=0;end
              if(wdata_i[0]) begin
                done_q[channel]<=0;
                error_q[channel]<=!descriptor_ok[channel];
                error_code_q[channel]<=descriptor_ok[channel] ? 4'd0 : 4'd1;
                if(descriptor_ok[channel]) start_o[channel]<=1;
              end
            end
          end
          8'h08: src_o[channel]<=wdata_i;
          8'h0c: dst_o[channel]<=wdata_i;
          8'h10: row_bytes_o[channel]<=wdata_i;
          8'h14: rows_o[channel]<=wdata_i;
          8'h18: src_stride_o[channel]<=wdata_i;
          8'h1c: dst_stride_o[channel]<=wdata_i;
          8'h20: mode_o[channel]<=wdata_i;
          8'h24: fill_o[channel]<=wdata_i;
          8'h34: timeout_o[channel]<=wdata_i;
          default: ;
        endcase
      end
    end
  end
endmodule
