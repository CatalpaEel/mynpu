#include "../sw/npu_plan.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
struct fake {
  uint32_t registers[1024], data;
  unsigned fences, relaxes;
};
static uint32_t read_io(void *ctx, uint32_t a) {
  struct fake *f = ctx;
  return a == 0x80000000u ? f->data : f->registers[(a & 4095u) / 4];
}
static void write_io(void *ctx, uint32_t a, uint32_t b) {
  struct fake *f = ctx;
  if (a == 0x80000000u)
    f->data = b;
  else
    f->registers[(a & 4095u) / 4] = b;
}
static void fence_io(void *ctx) { ((struct fake *)ctx)->fences++; }
static void relax_io(void *ctx) {
  struct fake *f = ctx;
  f->relaxes++;
  f->registers[0x128 / 4]++;
}
int main(void) {
  struct fake f = {0};
  struct npu_plan_io io = {&f, read_io, write_io, fence_io, relax_io};
  size_t failed;
  struct npu_plan_command commands[] = {{NPU_PLAN_WRITE, 0x80000000u, 31},
                                        {NPU_PLAN_CHECK, 0x80000000u, 31},
                                        {NPU_PLAN_SPACE, 0, 0},
                                        {NPU_PLAN_WAIT, 0, 1}};
  f.registers[0x124 / 4] = 8u << 16;
  f.registers[0x12c / 4] = f.registers[0x128 / 4] = 0xffffffffu;
  assert(npu_plan_execute(commands, 4, &io, 8, &failed) == 0);
  assert(failed == SIZE_MAX && f.relaxes == 1 && f.fences >= 4);
  f.registers[0x12c / 4] = f.registers[0x128 / 4];
  commands[1].b = 32;
  assert(npu_plan_execute(commands, 4, &io, 8, &failed) == NPU_PLAN_MISMATCH && failed == 1);
  commands[1].b = 31;
  f.registers[0x104 / 4] = 4;
  assert(npu_plan_execute(commands, 4, &io, 8, &failed) == NPU_PLAN_FAULT);
  f.registers[0x104 / 4] = 1;
  assert(npu_plan_execute(commands, 4, &io, 8, &failed) == NPU_PLAN_NOT_IDLE);
  f.registers[0x104 / 4] = 0;
  io.relax = NULL;
  assert(npu_plan_execute(commands, 4, &io, 2, &failed) == NPU_PLAN_TIMEOUT && failed == 3);
  commands[3].a = 3;
  assert(npu_plan_execute(commands, 4, &io, 2, &failed) == NPU_PLAN_INVALID && failed == 3);
  commands[3].a = 0;
  commands[3].b = 0x80000000u;
  assert(npu_plan_execute(commands, 4, &io, 2, &failed) == NPU_PLAN_INVALID);
  assert(npu_plan_execute(NULL, 1, &io, 2, &failed) == NPU_PLAN_INVALID);
  assert(npu_plan_execute(commands, 4, &io, 0, &failed) == NPU_PLAN_INVALID);
  puts("PLAN EXECUTOR PASS completion-wrap, faults, idle, timeout, validation");
}
