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
  CHECK(npu_stream_task(31, 31, 8, 7, 1, 1, 511) == 0xfffe3ff0u);
  printf(
      "STREAM SOFTWARE CHECK PASS checks=%u shape, borders, aliases, overflow, command encoding\n",
      checks);
}
