/* Exercise the real C row adapter with four FIFO slots and eight windows.
 * The mock implements MMIO queue backpressure, not the CNN arithmetic. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static uint32_t mock_read(uint32_t address);
static void mock_write(uint32_t address, uint32_t value);
static void mock_fence(void);
#define NPU_MMIO_READ32(address) mock_read(address)
#define NPU_MMIO_WRITE32(address, value) mock_write(address, value)
#define NPU_IO_FENCE() mock_fence()
#include "../sw/npu.h"
static uint32_t registers[1024], commands[16];
static unsigned queued, submitted, polls, full_polls, fences, peak;
static int stalled, fault;
static uint32_t mock_read(uint32_t address) {
  unsigned offset = address - NPU_MMIO_BASE;
  assert(offset < 4096 && !(offset & 3));
  if (offset == NPU_REGFILE_CAP)
    return 32;
  if (offset == NPU_STREAM_ABI)
    return NPU_STREAM_ABI_V5;
  if (offset == NPU_CNN_SUBMITTED)
    return submitted;
  if (offset == 0x604)
    return fault ? NPU_ERROR : (queued ? NPU_BUSY : 0);
  if (offset == NPU_CNN_QUEUE) {
    polls++;
    if (queued == 4)
      full_polls++;
    if (!stalled && queued && polls % 9 == 0)
      queued--;
    return (4u << 16) | queued;
  }
  return registers[offset / 4];
}
static void mock_write(uint32_t address, uint32_t value) {
  unsigned offset = address - NPU_MMIO_BASE;
  assert(offset < 4096 && !(offset & 3));
  registers[offset / 4] = value;
  if (offset == 0x600 && (value & 1u)) {
    assert(queued < 4 && submitted < 16);
    commands[submitted++] = registers[NPU_CNN_WINDOW / 4];
    queued++;
    if (queued > peak)
      peak = queued;
  }
}
static void mock_fence(void) { fences++; }
static void reset(void) {
  memset(registers, 0, sizeof(registers));
  memset(commands, 0, sizeof(commands));
  queued = submitted = polls = full_polls = fences = peak = 0;
  stalled = fault = 0;
}
int main(void) {
  struct npu_cnn_descriptor row = {0x80001000u, 0x80002000u, 0x80003000u, 128, 1, 1,
                                   1,           128,         0,           0,   0};
  reset();
  /* Nonblocking legacy entry retains its whole-row capacity contract. */
  assert(npu_cnn_start(&row) == -1 && submitted == 0);
  assert(npu_cnn_start_wait(&row, 1000) == 0 && submitted == 8);
  assert(peak == 4 && full_polls > 0 && fences >= 9);
  for (unsigned i = 0; i < 8; i++)
    assert(commands[i] == npu_stream_task(0, i * 16, 16, 2, i == 0, i == 7, i * 16));
  reset();
  queued = 4;
  stalled = 1;
  assert(npu_cnn_start_wait(&row, 3) == -2 && submitted == 0);
  reset();
  queued = 4;
  stalled = 1;
  fault = 1;
  assert(npu_cnn_start_wait(&row, 3) == -1 && submitted == 0);
  reset();
  row.dst = row.src;
  assert(npu_cnn_start_wait(&row, 1000) == -1 && submitted == 0);
  assert(npu_cnn_start_wait(NULL, 1000) == -1);
  puts("CNN ENQUEUE PASS depth=4 windows=8 backpressure/order/bounds/timeout/fault");
}
