// SD91: shared immutable transfer configuration, 32-bit software-prepared tasks.
package npu_stream_pkg;
  import npu_addr_pkg::*;
  localparam int CNN_MACS = 9, CNN_MAX_DIM = 28, STREAM_PARTIAL_WORDS = 8;
  typedef struct packed {
    logic [14:0] src, weights, dst, partial;
    logic [14:0] row_stride, plane_stride;
    logic [8:0] ci;
    logic step2;
    logic [7:0] offset;
  } stream_config_t;
  typedef struct packed {
    logic [8:0] dst_words;
    logic right_pad, left_pad;
    logic [2:0] row_mask;
    logic [3:0] count;
    logic [4:0] x, y;
    logic [3:0] co;
  } stream_task_t;
  typedef struct packed {
    logic busy, start, done, fault, issue, waiting, mac_valid;
    logic [2:0] mem;
    logic [3:0] macs;
  } stream_events_t;
  function automatic logic [31:0] encode_task(input int co, y, x, count, rows, left_pad, right_pad,
                                              dst_words);
    return 32'(co) | 32'(y)<<4 | 32'(x)<<9 | 32'(count)<<14 | 32'(rows)<<18 |
      32'(left_pad)<<21 | 32'(right_pad)<<22 | 32'(dst_words)<<23;
  endfunction
endpackage
