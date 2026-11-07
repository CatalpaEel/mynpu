// Shared data address contract. SRAM holds code/weights/I/O; the extra aperture
// is a software-managed regfile for live intermediate tensors, not a cache alias.
`ifndef NPU_RF_BANK_WORDS
`define NPU_RF_BANK_WORDS 256
`endif
package npu_addr_pkg;
  localparam int RF_BANK_WORDS = `NPU_RF_BANK_WORDS;
  localparam int RF_BANK_BITS = $clog2(RF_BANK_WORDS);
  localparam int RF_BYTES = RF_BANK_WORDS * 8;
  localparam logic [31:0] SRAM_BASE = 32'h80000000, RF_BASE = 32'h80004000;
  function automatic logic is_rf_address(input logic [31:0] addr);
    return addr >= RF_BASE && addr < RF_BASE + RF_BYTES;
  endfunction
  // Four ordered stream endpoints. Low byte is a wrapping cursor, not storage.
  localparam logic [31:0] STREAM_BASE = 32'h80006000, STREAM_END = 32'h80006400;
  function automatic logic is_stream_address(input logic [31:0] a);
    return a >= STREAM_BASE && a < STREAM_END;
  endfunction
  function automatic logic [31:0] data_advance(input logic [31:0] a, delta);
    return is_stream_address(a) ? {a[31:8], 8'(a[7:0] + delta)} : a + delta;
  endfunction
  function automatic logic data_range_ok(input logic [31:0] base, bytes);
    logic [32:0] ending;
    ending = {1'b0, base} + {1'b0, bytes};
    return bytes != 0 && (is_stream_address(
        base
    ) || ((base[31:14] == 18'h20000 && ending <= {1'b0, RF_BASE}) || (is_rf_address(
        base
    ) && ending <= {1'b0, RF_BASE} + RF_BYTES)));
  endfunction
endpackage
