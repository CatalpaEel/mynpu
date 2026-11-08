// SD94: immutable input/kernel geometry and compact software window tasks.
package npu_stream_pkg;
  import npu_addr_pkg::*;
  localparam int CNN_MACS = 9, STREAM_PARTIAL_WORDS = 8;
  typedef struct packed {
    logic [14:0] src, kernel, dst, partial;
    logic [14:0] row_stride, plane_stride;
    logic [8:0] ci;
    logic step2;
    logic [7:0] offset;
  } stream_config_t;
  // Low to high: count-minus-one, reserved context bit, mask, borders, X/Y, output offset.
  typedef struct packed {
    logic [8:0] dst_words;
    logic [6:0] y, x;
    logic right_pad, left_pad;
    logic [2:0] row_mask;
    logic reserved_context;
    logic [2:0] count_m1;
  } stream_task_t;
  typedef struct packed {
    logic busy, start, done, fault, issue, waiting, mac_valid;
    logic [2:0] mem;
    logic [3:0] macs;
  } stream_events_t;
  function automatic logic [31:0] encode_task(input int y, x, count, rows, left_pad, right_pad,
                                              dst_words);
    if (count < 1 || count > STREAM_PARTIAL_WORDS) return 32'h8;
    return 32'(count-1) | 32'(rows)<<4 | 32'(left_pad)<<7 | 32'(right_pad)<<8 |
      32'(x)<<9 | 32'(y)<<16 | 32'(dst_words)<<23;
  endfunction
endpackage
