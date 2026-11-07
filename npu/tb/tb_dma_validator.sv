`timescale 1ns / 1ps
module tb_dma_validator;
  logic clk_i = 0, rst_ni = 0, req_i = 0, we_i = 0;
  always #5 clk_i = ~clk_i;
  logic [11:0] addr_i = 0;
  logic [31:0] wdata_i = 0;
  logic [2:0] busy_i = 0, done_i = 0, fault_i = 0;
  logic [2:0][3:0] fault_code_i = 0;
  logic [2:0][31:0] bytes_done_i = 0, cycles_i = 0;
  wire [31:0] d_rdata;
  wire d_error;
  wire [2:0] d_start, d_abort, d_irq;
  wire [2:0][31:0] d_src, d_dst, d_row_bytes, d_rows, d_src_stride, d_dst_stride, d_mode, d_fill, d_timeout;
  npu_dma_regs d (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (req_i),
    .we_i        (we_i),
    .addr_i      (addr_i),
    .wdata_i     (wdata_i),
    .busy_i      (busy_i),
    .done_i      (done_i),
    .fault_i     (fault_i),
    .fault_code_i(fault_code_i),
    .bytes_done_i(bytes_done_i),
    .cycles_i    (cycles_i),
    .rdata_o     (d_rdata),
    .error_o     (d_error),
    .start_o     (d_start),
    .abort_o     (d_abort),
    .irq_o       (d_irq),
    .src_o       (d_src),
    .dst_o       (d_dst),
    .row_bytes_o (d_row_bytes),
    .rows_o      (d_rows),
    .src_stride_o(d_src_stride),
    .dst_stride_o(d_dst_stride),
    .mode_o      (d_mode),
    .fill_o      (d_fill),
    .timeout_o   (d_timeout)
  );
  wire [31:0] r_rdata;
  wire r_error;
  wire [2:0] r_start, r_abort, r_irq;
  wire [2:0][31:0] r_src, r_dst, r_row_bytes, r_rows, r_src_stride, r_dst_stride, r_mode, r_fill, r_timeout;
  npu_dma_regs_reference r (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (req_i),
    .we_i        (we_i),
    .addr_i      (addr_i),
    .wdata_i     (wdata_i),
    .busy_i      (busy_i),
    .done_i      (done_i),
    .fault_i     (fault_i),
    .fault_code_i(fault_code_i),
    .bytes_done_i(bytes_done_i),
    .cycles_i    (cycles_i),
    .rdata_o     (r_rdata),
    .error_o     (r_error),
    .start_o     (r_start),
    .abort_o     (r_abort),
    .irq_o       (r_irq),
    .src_o       (r_src),
    .dst_o       (r_dst),
    .row_bytes_o (r_row_bytes),
    .rows_o      (r_rows),
    .src_stride_o(r_src_stride),
    .dst_stride_o(r_dst_stride),
    .mode_o      (r_mode),
    .fill_o      (r_fill),
    .timeout_o   (r_timeout)
  );
  int dc[3], rc[3], checks = 0;
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int c = 0; c < 3; c++) begin
        dc[c] = 0;
        rc[c] = 0;
      end
    end else
      for (int c = 0; c < 3; c++) begin
        if (d_start[c]) dc[c]++;
        if (r_start[c]) rc[c]++;
      end
  end
  task automatic write_reg(input int c, offset, input logic [31:0] value);
    @(negedge clk_i);
    req_i = 1;
    we_i = 1;
    addr_i = 12'('h300 + c * 'h100 + offset);
    wdata_i = value;
    @(posedge clk_i);
    #1;
  endtask
  task automatic idle;
    @(negedge clk_i);
    req_i = 0;
    we_i = 0;
  endtask
  initial begin
    for (int wave = 0; wave < 64; wave++) begin
      @(negedge clk_i);
      rst_ni = 0;
      req_i = 0;
      we_i = 0;
      repeat (2) @(negedge clk_i);
      rst_ni = 1;
      for (int c = 0; c < 3; c++) begin
        logic [31:0] src, dst, bytes, rows, ss, ds;
        src = 32'h80000000 + wave * 4;
        dst = 32'h80002000 + wave * 8;
        bytes = 1 + wave % 9;
        rows = 1 + wave % 4;
        ss = 64;
        ds = 64;
        case (wave % 8)
          1: if (c == wave % 3) bytes = 0;
          2: if (c == wave % 3) rows = 2049;
          3: if (c == wave % 3) ss = 2;
          4: begin
            src = 32'h80003ffc;
            bytes = 16;
            rows = 1;
          end
          5: begin
            dst = npu_addr_pkg::RF_BASE + npu_addr_pkg::RF_BYTES - 4;
            bytes = 16;
            rows = 1;
          end
          6:
          if (c == 2) begin
            dst = src + 4;
            bytes = 32;
            rows = 1;
          end
          7: begin
            rows = 2;
            ss = 0;
            ds = 0;
          end
          default: ;
        endcase
        write_reg(c, 'h08, src);
        write_reg(c, 'h0c, dst);
        write_reg(c, 'h10, bytes);
        write_reg(c, 'h14, rows);
        write_reg(c, 'h18, ss);
        write_reg(c, 'h1c, ds);
        write_reg(c, 'h20, c == 2 ? (wave[0] ? 3 : 2) : c);
        write_reg(c, 'h24, 32'h87654321);
        write_reg(c, 'h34, 1000);
      end
      // STARTs on consecutive bus cycles contend for one validation multiplier.
      for (int c = 0; c < 3; c++) write_reg(c, 0, 1);
      if (wave % 7 == 0) write_reg(2, 0, 4);  // cancel while both designs validate
      if (wave % 7 == 1) write_reg(2, 'h08, 32'hdeadbeef);  // occupied CSR write rejected
      idle();
      repeat (24) @(negedge clk_i);
      for (int c = 0; c < 3; c++) begin
        if (dc[c] != rc[c])
          $fatal(1, "start mismatch wave=%0d channel=%0d new=%0d old=%0d", wave, c, dc[c], rc[c]);
        checks++;
        for (int offset = 0; offset <= 'h34; offset += 4) begin
          addr_i = 12'('h300 + c * 'h100 + offset);
          #1;
          if (d_rdata !== r_rdata || d_error !== r_error)
            $fatal(
                1,
                "CSR mismatch wave=%0d channel=%0d offset=%h new=%h old=%h",
                wave,
                c,
                offset,
                d_rdata,
                r_rdata
            );
          checks++;
        end
      end
      if (d_irq !== r_irq) $fatal(1, "IRQ mismatch");
      checks++;
    end
    $display(
        "DMA VALIDATOR PASS waves=64 descriptors=192 checks=%0d concurrency, bounds, overlap, abort, blocked writes",
        checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
