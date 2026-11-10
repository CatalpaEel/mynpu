#include "../sw/npu.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
  struct npu_cnn_descriptor d = {0x80001400u, 0x80002000u, 0x80003d00u, 28,  28, 1,
                                 2,           14,          0,           128, 0};
  unsigned checks = 0;
#define CHECK(v)                                                                                   \
  do {                                                                                             \
    assert(v);                                                                                     \
    ++checks;                                                                                      \
  } while (0)
  CHECK(npu_cnn_descriptor_valid(&d, 256));
  for (unsigned stride = 1; stride <= 2; stride++)
    for (unsigned w = 1; w <= 28; w++)
      for (unsigned y = 0; y < (w + stride - 1) / stride; y++) {
        d.width = w;
        d.height = w;
        d.stride = stride;
        d.output_width = (w + stride - 1) / stride;
        d.output_row = y;
        CHECK(npu_cnn_descriptor_valid(&d, 256));
      }
  d.width = 3;
  d.height = 3;
  d.cin = 8;
  d.stride = 1;
  d.output_width = 3;
  d.output_row = 0;
  d.src = NPU_REGFILE_BASE;
  d.dst = NPU_REGFILE_BASE + 72;
  CHECK(npu_cnn_descriptor_valid(&d, 256));
  d.dst = NPU_REGFILE_BASE + 240;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  d.dst = NPU_REGFILE_BASE;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  d.dst = 0;
  d.op = 0;
  d.dst = 0x80003d00u;
  CHECK(npu_cnn_descriptor_valid(&d, 256));
  d.src = NPU_REGFILE_BASE + 184;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  d.src = NPU_SRAM_BASE;
  d.op = 1;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  d.op = 2;
  d.width = 0xffffff01u;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  d.width = 3;
  d.input_zero = 256;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  CHECK(!npu_data_span(0xfffffffcu, 8, 256));
  CHECK(!npu_data_span(NPU_REGFILE_BASE + 256, 1, 256));
  CHECK(npu_stream_task(127, 127, 8, 7, 1, 1, 511) == 0xfffffff7u);
  CHECK(npu_vector_insn(1, 2, 3, 1, -7, 1) == 0xffff97a1u);
  CHECK(npu_vector_shift_pair(22, 1, 2, 3, 32) ==
        (22u | (1u << 6) | (2u << 8) | (3u << 10) | (32u << 12)));
  CHECK(npu_vector_shift_pair(22, 1, 2, 3, 33) == 31u);
  d.src = 0x80001400u;
  d.weights = 0x80002000u;
  d.dst = 0x80003d00u;
  d.width = 1;
  d.height = 128;
  d.cin = 1;
  d.stride = 1;
  d.output_width = 1;
  d.output_row = 127;
  d.input_zero = 0;
  d.op = 0;
  CHECK(npu_cnn_descriptor_valid(&d, 256));
  d.output_row = 128;
  CHECK(!npu_cnn_descriptor_valid(&d, 256));
  for (unsigned count = 1; count <= 16; count++) {
    uint32_t task = npu_stream_task(0, 0, count, 0, 0, 0, 0);
    CHECK((task & 15u) == count - 1);
  }
  uint32_t packed = 0xdeadbeefu;
  CHECK(npu_stream_task_checked(0, 0, 0, 0, 0, 0, 0, &packed) == -1 && packed == 0xdeadbeefu);
  CHECK(npu_stream_task_checked(0, 0, 17, 0, 0, 0, 0, &packed) == -1 && packed == 0xdeadbeefu);
  CHECK(npu_stream_task_checked(0, 0, 16, 0, 0, 0, 0, &packed) == 0 && packed == 15u);
  CHECK(npu_stream_task(127, 127, 16, 7, 1, 1, 511) == 0xffffffffu);
  CHECK(npu_stream_task_checked(128, 0, 1, 0, 0, 0, 0, &packed) == -1);
  CHECK(npu_stream_task_checked(0, 128, 1, 0, 0, 0, 0, &packed) == -1);
  CHECK(npu_stream_task_checked(0, 0, 1, 8, 0, 0, 0, &packed) == -1);
  CHECK(npu_stream_task_checked(0, 0, 1, 0, 0, 0, 512, &packed) == -1);
  CHECK(npu_counter_reached(7, 7));
  CHECK(npu_counter_reached(8, 7));
  CHECK(!npu_counter_reached(6, 7));
  CHECK(npu_counter_reached(0, 0xffffffffu));
  CHECK(!npu_counter_reached(0xffffffffu, 0));
  CHECK(NPU_QUANT_SYNC_BASE(NPU_QUANT_MATRIX) + NPU_QUANT_WRITTEN == 0x76cu);
  CHECK(NPU_SYNC_ABI_V2 == 0x0002007fu);
  CHECK(NPU_QUANT_SYNC_BASE(NPU_QUANT_MATRIX) + NPU_QUANT_WRITE_CANCELLED == 0x77cu);
  struct npu_vector_layout layout = {0, -4, 0, NPU_VEC_STRIDES, npu_task_events(3, 4)};
  CHECK(npu_vector_layout_valid(&layout, 0));
  CHECK(layout.events == 0x0403u);
  layout.d_stride = -3;
  CHECK(!npu_vector_layout_valid(&layout, 0));
  CHECK(npu_vector_layout_valid(&layout, 1));
  layout.a_stride = 32768;
  CHECK(!npu_vector_layout_valid(&layout, 1));
  layout.a_stride = -32768;
  CHECK(npu_vector_layout_valid(&layout, 1));
  printf(
      "STREAM SOFTWARE CHECK PASS checks=%u shape, borders, aliases, overflow, command encoding\n",
      checks);
}
