#ifndef NPU_PLAN_H
#define NPU_PLAN_H
#include <stddef.h>
#include <stdint.h>

/* Portable executor for task_graph.py plans. read/write callbacks access both
 * memory and MMIO; fence must order device accesses. IRQ/WFI may be implemented
 * by relax, but relax must also return without an interrupt (avoid lost wakes).
 * A plan starts with all three queues idle and no sticky error. No reset needed.
 * One serialized software producer owns configuration and submission registers.
 */
enum npu_plan_opcode {
  NPU_PLAN_WRITE,
  NPU_PLAN_SPACE,
  NPU_PLAN_WAIT,
  NPU_PLAN_CHECK,
  NPU_PLAN_MARK
};
struct npu_plan_command {
  uint32_t op, a, b;
};
struct npu_plan_io {
  void *context;
  uint32_t (*read)(void *, uint32_t);
  void (*write)(void *, uint32_t, uint32_t);
  void (*fence)(void *);
  void (*relax)(void *);
};
enum npu_plan_result {
  NPU_PLAN_OK = 0,
  NPU_PLAN_INVALID = -1,
  NPU_PLAN_FAULT = -2,
  NPU_PLAN_TIMEOUT = -3,
  NPU_PLAN_MISMATCH = -4,
  NPU_PLAN_NOT_IDLE = -5
};
static inline int npu_plan_execute(const struct npu_plan_command *commands, size_t count,
                                   const struct npu_plan_io *io, uint32_t timeout,
                                   size_t *failed_command) {
  static const uint32_t control[3] = {0x100, 0x200, 0x600};
  static const uint32_t queue[3] = {0x124, 0x224, 0x658};
  static const uint32_t submitted[3] = {0x12c, 0x22c, 0x660};
  static const uint32_t completed[3] = {0x128, 0x228, 0x65c};
  const uint32_t base = 0x40000000u;
  uint32_t baseline[3];
  if (failed_command)
    *failed_command = SIZE_MAX;
  if ((!commands && count) || !io || !io->read || !io->write || !io->fence || !timeout)
    return NPU_PLAN_INVALID;
  io->fence(io->context);
  for (unsigned u = 0; u < 3; u++) {
    uint32_t status = io->read(io->context, base + control[u] + 4);
    uint32_t q = io->read(io->context, base + queue[u]);
    baseline[u] = io->read(io->context, base + submitted[u]);
    if (status & 4u)
      return NPU_PLAN_FAULT;
    if ((status & 1u) || (q & 0xffffu) || io->read(io->context, base + completed[u]) != baseline[u])
      return NPU_PLAN_NOT_IDLE;
  }
  for (size_t i = 0; i < count; i++) {
    const struct npu_plan_command c = commands[i];
    int result = NPU_PLAN_OK;
    if (c.op == NPU_PLAN_WRITE) {
      io->write(io->context, c.a, c.b);
      io->fence(io->context);
    } else if (c.op == NPU_PLAN_CHECK) {
      if (io->read(io->context, c.a) != c.b)
        result = NPU_PLAN_MISMATCH;
    } else if (c.op == NPU_PLAN_WAIT || c.op == NPU_PLAN_SPACE) {
      if (c.a >= 3 || (c.op == NPU_PLAN_WAIT && (!c.b || c.b >= 0x80000000u))) {
        result = NPU_PLAN_INVALID;
      } else {
        result = NPU_PLAN_TIMEOUT;
        for (uint32_t t = 0; t < timeout; t++) {
          if (io->read(io->context, base + control[c.a] + 4) & 4u) {
            result = NPU_PLAN_FAULT;
            break;
          }
          uint32_t value =
              io->read(io->context, base + (c.op == NPU_PLAN_SPACE ? queue[c.a] : completed[c.a]));
          if (c.op == NPU_PLAN_SPACE ? (value & 0xffffu) < (value >> 16)
                                     : value - (baseline[c.a] + c.b) < 0x80000000u) {
            io->fence(io->context);
            result = NPU_PLAN_OK;
            break;
          }
          if (io->relax)
            io->relax(io->context);
        }
      }
    } else if (c.op != NPU_PLAN_MARK)
      result = NPU_PLAN_INVALID;
    if (result) {
      if (failed_command)
        *failed_command = i;
      return result;
    }
  }
  return NPU_PLAN_OK;
}
#endif
