#ifndef NPU_H
#define NPU_H
#include <stdint.h>
/* Local machine interrupt IDs. Boot wake remains IRQ31. */
#define NPU_IRQ_MATRIX 16u
#define NPU_IRQ_VECTOR 17u
#define NPU_IRQ_CNN 18u
#define NPU_IRQ_MASK 0x00070000u
#define NPU_IRQ_CAP 0x070u
#define NPU_CONTROL_START 1u
#define NPU_CONTROL_CLEAR_IDLE 2u
#define NPU_CONTROL_ACK_DONE 8u
#define NPU_SRAM_BASE 0x80000000u
#define NPU_SRAM_BYTES 16384u
#define NPU_BANK_BYTES 8192u
#define NPU_BANK0_BASE NPU_SRAM_BASE
#define NPU_BANK1_BASE (NPU_SRAM_BASE + NPU_BANK_BYTES)
/* Uncached SRAM: legacy hits read zero; former misses count SRAM read requests. */
#define NPU_SRAM_READS0 0x028u
#define NPU_SRAM_READS1 0x02cu
#define NPU_CACHE_HITS0 0x020u
#define NPU_CACHE_HITS1 0x024u
#define NPU_CACHE_MISSES0 0x028u
#define NPU_CACHE_MISSES1 0x02cu
#define NPU_STREAM_CHANNEL_CAP 0x060u
#define NPU_STREAM_CHANNEL_BASE 0x064u
#define NPU_STREAM_ENDPOINT(channel) (0x80006000u + ((uint32_t)(channel) << 8))
#define NPU_MEMORY_CAP 0x038u
#define NPU_CACHE_CAP 0x03cu
#define NPU_REGFILE_CAP 0x050u
#define NPU_REGFILE_BASE_REG 0x054u
#define NPU_REGFILE_BASE 0x80004000u
static inline uint32_t npu_regfile_bank_bytes(void);
#define NPU_MAT_CONTROL 0x100u
#define NPU_MAT_STATUS 0x104u
#define NPU_VEC_CONTROL 0x200u
#define NPU_VEC_STATUS 0x204u
#define NPU_MAT_QUEUE 0x124u
#define NPU_MAT_COMPLETED 0x128u
#define NPU_MAT_SUBMITTED 0x12cu
#define NPU_VEC_QUEUE 0x224u
#define NPU_VEC_COMPLETED 0x228u
#define NPU_VEC_SUBMITTED 0x22cu
/* Operator ABI 1.0, project-defined integer kernels (not an ISA extension). */
#define NPU_OPERATOR_ABI 0x040u
#define NPU_GEMM_CAP 0x044u
#define NPU_VECTOR_CAP 0x048u
#define NPU_CNN_CAP 0x04cu
#define NPU_MAT_FLAGS 0x130u
#define NPU_VEC_SCALAR 0x230u
#define NPU_GEMM_TRANS_A 1u
#define NPU_GEMM_TRANS_B 2u
#define NPU_GEMM_ACCUMULATE 4u
#define NPU_GEMM_PACKED 8u
#define NPU_GEMM_INT16 16u
#define NPU_VECTOR_SCALAR 128u
enum npu_vector_op {
  NPU_V_RELU = 0,
  NPU_V_ADD = 1,
  NPU_V_COPY = 2,
  NPU_V_SUB = 3,
  NPU_V_MIN = 4,
  NPU_V_MAX = 5,
  NPU_V_AND = 6,
  NPU_V_OR = 7,
  NPU_V_XOR = 8,
  NPU_V_SHL = 9,
  NPU_V_SHR = 10,
  NPU_V_SAR = 11,
  NPU_V_EQ = 12,
  NPU_V_NEG = 13,
  NPU_V_ABS = 14,
  NPU_V_NOT = 15,
  NPU_V_MUL32 = 24,
  NPU_V_RSHR32 = 26,
  NPU_V_LD32 = 27,
  NPU_V_ADDC = 16,
  NPU_V_ADC = 17,
  NPU_V_SLTU = 18,
  NPU_V_MULHU = 19,
  NPU_V_MULH = 20,
  NPU_V_SHRD = 21,
  NPU_V_RSHRD = 22,
  NPU_V_ADCSX = 23,
  NPU_V_SCALAR = 29
};
enum npu_cnn_op { NPU_CONV = 0, NPU_FC = 1 };
#define NPU_V_PROGRAM 32u
#define NPU_V_SIMD8 64u
#define NPU_V_SCALAR_INPUT 128u
#define NPU_VECTOR_SIMD_CAP 0x068u
#define NPU_V_PACK_U8 128u
#define NPU_VECTOR_PROGRAM_ABI 0x058u
#define NPU_VECTOR_PROGRAM_ABI_V2 0x56504732u
#define NPU_VEC_PROGRAM_CFG 0x234u
#define NPU_VEC_PROGRAM_WORDS 0x240u
struct npu_gemm_descriptor {
  uint32_t a, b, d, m, n, k, flags;
};
struct npu_vector_descriptor {
  uint32_t a, b, d, len, op, scalar;
};
#define NPU_MMIO_BASE 0x40000000u
#define NPU_BUSY 1u
#define NPU_DONE 2u
#define NPU_ERROR 4u
static inline void npu_write(uint32_t offset, uint32_t value) {
  *(volatile uint32_t *)(uintptr_t)(NPU_MMIO_BASE + offset) = value;
}
static inline uint32_t npu_read(uint32_t offset) {
  return *(volatile uint32_t *)(uintptr_t)(NPU_MMIO_BASE + offset);
}
/* Read only NPU-local pending sources; CPU mie controls wake/interrupt masks. */
static inline uint32_t npu_irq_pending(void) {
  uint32_t value;
  __asm__ volatile("csrr %0, mip" : "=r"(value));
  return value & NPU_IRQ_MASK;
}
/* Acknowledge done while active; error and completion counters are unchanged. */
static inline void npu_irq_ack_done(uint32_t control_offset) {
  npu_write(control_offset, NPU_CONTROL_ACK_DONE);
}
static inline void npu_fence(void) { __asm__ volatile("fence iorw, iorw" ::: "memory"); }
static inline uint32_t npu_regfile_bank_bytes(void) {
  return (npu_read(NPU_REGFILE_CAP) & 65535u) * 4u;
}
/* Returns 0 on completion, -1 on command error, -2 on timeout. */
static inline int npu_wait(uint32_t status_offset, uint32_t timeout) {
  while (timeout--) {
    uint32_t s = npu_read(status_offset);
    if (s & NPU_ERROR)
      return -1;
    if ((s & (NPU_BUSY | NPU_DONE)) == NPU_DONE) {
      npu_fence();
      return 0;
    }
  }
  return -2;
}
/* Nonblocking descriptor enqueue; software must serialize shadow-CSR producers.
 * Queue depth excludes the active job. A snapshot is captured on CONTROL.start.
 * Buffer dependencies across queued jobs/units remain a software responsibility. */
static inline int npu_queue_has_space(uint32_t offset) {
  uint32_t q = npu_read(offset);
  return (q & 0xffffu) < (q >> 16);
}
/* Completion tickets are modulo 2^32; keep fewer than 2^31 outstanding. */
static inline int npu_queue_wait(uint32_t completed, uint32_t status, uint32_t ticket,
                                 uint32_t timeout) {
  while (timeout--) {
    if (npu_read(status) & NPU_ERROR)
      return -1;
    if ((int32_t)(npu_read(completed) - ticket) >= 0) {
      npu_fence();
      return 0;
    }
  }
  return -2;
}
static inline int npu_matmul_start(uint32_t a, uint32_t b, uint32_t d, uint32_t m, uint32_t n,
                                   uint32_t k) {
  if (!npu_queue_has_space(NPU_MAT_QUEUE))
    return -1;
  uint32_t before = npu_read(NPU_MAT_SUBMITTED);
  npu_write(0x108, a);
  npu_write(0x10c, b);
  npu_write(0x110, d);
  npu_write(0x114, m);
  npu_write(0x118, n);
  npu_write(0x11c, k);
  npu_write(NPU_MAT_FLAGS, 0);
  npu_fence();
  npu_write(0x100, 1);
  return npu_read(NPU_MAT_SUBMITTED) == before + 1u ? 0 : -1;
}
static inline int npu_vector_start(uint32_t a, uint32_t b, uint32_t d, uint32_t len, uint32_t op) {
  if (op > 15u)
    return -1; /* Scalar form uses npu_elementwise_start. */
  if (!npu_queue_has_space(NPU_VEC_QUEUE))
    return -1;
  uint32_t before = npu_read(NPU_VEC_SUBMITTED);
  npu_write(0x208, a);
  npu_write(0x218, b);
  npu_write(0x20c, d);
  npu_write(0x210, len);
  npu_write(0x214, op);
  npu_fence();
  npu_write(0x200, 1);
  return npu_read(NPU_VEC_SUBMITTED) == before + 1u ? 0 : -1;
}
/* Dense row-major GEMM, D=op(A)*op(B), or D+= when ACCUMULATE.
 * All bases are 4-byte aligned; packed rows need no padding. INT32 output.
 * Inputs: signed INT8/INT16; arithmetic accumulates modulo 2^32. */
/* Per-job limits; address capacity can impose a tighter bound. */
#define NPU_MATRIX_SHAPE_CAP 0x074u /* [31:16]=K, [15:8]=N, [7:0]=M */
#define NPU_VECTOR_LENGTH_CAP 0x078u
#define NPU_CNN_INPUT_CHANNEL_CAP 0x07cu
#define NPU_MATRIX_MAX_M 16u
#define NPU_MATRIX_MAX_N 16u
#define NPU_MATRIX_MAX_K 256u
#define NPU_VECTOR_MAX_ELEMENTS 4096u
#define NPU_CNN_MAX_INPUT_CHANNELS 256u
#define NPU_MATRIX_OUTER_CAP 0x06cu
#define NPU_MATRIX_LDA 0x134u
#define NPU_MATRIX_LDB 0x138u
/* Shared per-batch element strides; zero chooses the dense leading dimension.
 * Finish all matrix jobs before changing them. K=0 with ACCUMULATE emits old D. */
static inline int npu_gemm_leading_dims(uint32_t lda, uint32_t ldb) {
  if (lda > 4096u || ldb > 4096u || (npu_read(NPU_MAT_STATUS) & NPU_BUSY) ||
      npu_read(NPU_MATRIX_OUTER_CAP) != 0x00030404u)
    return -1;
  npu_write(NPU_MATRIX_LDA, lda);
  npu_write(NPU_MATRIX_LDB, ldb);
  return 0;
}
static inline int npu_gemm_start(const struct npu_gemm_descriptor *d) {
  if ((npu_read(NPU_OPERATOR_ABI) >> 16) != 1u || (d->flags & ~npu_read(NPU_GEMM_CAP)))
    return -1;
  if (!npu_queue_has_space(NPU_MAT_QUEUE))
    return -1;
  uint32_t before = npu_read(NPU_MAT_SUBMITTED);
  npu_write(0x108, d->a);
  npu_write(0x10c, d->b);
  npu_write(0x110, d->d);
  npu_write(0x114, d->m);
  npu_write(0x118, d->n);
  npu_write(0x11c, d->k);
  npu_write(NPU_MAT_FLAGS, d->flags);
  npu_fence();
  npu_write(0x100, 1);
  return npu_read(NPU_MAT_SUBMITTED) == before + 1u ? 0 : -1;
}
/* Optional direct CNN/Matrix result quantizer. Configure only after that
 * source's active and queued jobs drain. A zero control preserves raw INT32.
 * Destination describes the final output; Matrix D still names raw partials.
 */
#define NPU_QUANT_CNN 0u
#define NPU_QUANT_MATRIX 1u
#define NPU_QUANT_CAP 0x780u
#define NPU_QUANT_ABI 0x51543031u
struct npu_quant_config {
  uint32_t control, multiplier, bias, shift, zero, lower, upper, input_offset, dst;
};
static inline int npu_quant_configure(uint32_t source, const struct npu_quant_config *q) {
  if (source > 1u || !q || npu_read(NPU_QUANT_CAP) != NPU_QUANT_ABI || q->control > 3u ||
      q->control == 2u || q->shift > 32u || (int32_t)q->lower > (int32_t)q->upper ||
      (q->control == 1u && (q->dst & 3u)) ||
      (q->control == 3u && q->dst >= 0x80006000u && q->dst < 0x80006400u) ||
      (npu_read(source ? NPU_MAT_STATUS : 0x604u) & NPU_BUSY))
    return -1;
  uint32_t base = 0x700u + source * 64u;
  if (q->control && !((q->dst - NPU_SRAM_BASE < NPU_SRAM_BYTES) ||
                      (q->dst - NPU_REGFILE_BASE < 2u * npu_regfile_bank_bytes()) ||
                      (q->control == 1u && q->dst >= 0x80006000u && q->dst < 0x80006400u)))
    return -1;
  npu_write(base, 0);
  if (!q->control)
    return 0;
  npu_write(base + 4, q->multiplier);
  npu_write(base + 8, q->bias);
  npu_write(base + 12, q->shift);
  npu_write(base + 16, q->zero);
  npu_write(base + 20, q->lower);
  npu_write(base + 24, q->upper);
  npu_write(base + 28, q->input_offset);
  npu_write(base + 32, q->dst);
  npu_fence();
  npu_write(base, q->control);
  return 0;
}
static inline int npu_elementwise_start(const struct npu_vector_descriptor *d) {
  uint32_t opcode = d->op & 31u;
  int program = (d->op == 0x20u || d->op == 0xa0u || d->op == 0x60u);
  if ((npu_read(NPU_OPERATOR_ABI) >> 16) != 1u ||
      (program ? npu_read(NPU_VECTOR_PROGRAM_ABI) != NPU_VECTOR_PROGRAM_ABI_V2
               : ((d->op & ~0xdfu) != 0 || !(npu_read(NPU_VECTOR_CAP) & (1u << opcode)))))
    return -1;
  if (!npu_queue_has_space(NPU_VEC_QUEUE))
    return -1;
  uint32_t before = npu_read(NPU_VEC_SUBMITTED);
  npu_write(0x208, d->a);
  npu_write(0x218, d->b);
  npu_write(0x20c, d->d);
  npu_write(0x210, d->len);
  npu_write(0x214, d->op);
  npu_write(NPU_VEC_SCALAR, d->scalar);
  npu_fence();
  npu_write(0x200, 1);
  return npu_read(NPU_VEC_SUBMITTED) == before + 1u ? 0 : -1;
}
#define NPU_CPU_CONTROL 0x008u
#define NPU_CPU_BOOT_ADDR 0x00cu
/* Generic program configuration is writable only after the entire vector
 * queue drains. Instructions remain stable for all queued jobs. Each job has
 * four 32-bit temporaries: r0=input/result, initial r1=B, r2=0, r3=scalar.
 * Slots [0,loop) run once, [loop,count) repeat for each input element.
 * Packed U8 output stores the low byte; software must explicitly clamp.
 */
static inline uint32_t npu_vector_insn(unsigned op, unsigned rd, unsigned ra, unsigned rb,
                                       int immediate, int use_immediate) {
  return (op & 31u) | ((rd & 3u) << 5) | ((ra & 3u) << 7) | ((rb & 3u) << 9) |
         ((use_immediate != 0) << 11) | (((uint32_t)immediate & 0xfffffu) << 12);
}
/* SHRD/RSHRD take low/high registers and a 0..32 immediate shift. */
static inline uint32_t npu_vector_shift_pair(unsigned op, unsigned rd, unsigned low, unsigned high,
                                             unsigned shift) {
  return shift <= 32u ? npu_vector_insn(op, rd, low, high, 0, 0) | (shift << 14) : 31u;
}
static inline int npu_vector_program_configure(const uint32_t *words, unsigned count,
                                               unsigned loop) {
  if (count == 0 || count > 16 || loop >= count ||
      npu_read(NPU_VECTOR_PROGRAM_ABI) != NPU_VECTOR_PROGRAM_ABI_V2 ||
      (npu_read(NPU_VEC_STATUS) & NPU_BUSY))
    return -1;
  for (unsigned i = 0; i < count; i++)
    npu_write(NPU_VEC_PROGRAM_WORDS + 4 * i, words[i]);
  npu_write(NPU_VEC_PROGRAM_CFG, count | (loop << 8));
  npu_fence();
  return 0;
}
/* SD91 transfer ABI. CNN arithmetic is an independent ready/valid DOT9 unit.
 * Shared configuration is immutable until all queued transfer tasks drain. */
#define NPU_STREAM_ABI 0x654u
#define NPU_STREAM_ABI_V1 0x53443931u
#define NPU_CNN_QUEUE 0x658u
#define NPU_CNN_COMPLETED 0x65cu
#define NPU_CNN_SUBMITTED 0x660u
#define NPU_CNN_TOTAL_CYCLES 0x664u
#define NPU_CNN_TOTAL_MACS 0x668u
#define NPU_CNN_MAC_LANES 0x66cu
#define NPU_STREAM_TASK_CAP 0x670u
struct npu_stream_config {
  uint32_t src, weights, dst, row_stride, partial, cin, stride, plane_stride, input_zero, mode;
};
static inline int npu_data_span(uint32_t a, uint32_t n, uint32_t rf_bytes) {
  uint64_t end = (uint64_t)a + n;
  return n && ((a >= 0x80006000u && a < 0x80006400u) ||
               (a >= NPU_SRAM_BASE && end <= NPU_REGFILE_BASE) ||
               (a >= NPU_REGFILE_BASE && end <= (uint64_t)NPU_REGFILE_BASE + rf_bytes));
}
static inline int npu_spans_overlap(uint32_t a, uint32_t n, uint32_t b, uint32_t m) {
  return (uint64_t)a < (uint64_t)b + m && (uint64_t)b < (uint64_t)a + n;
}
static inline int npu_stream_configure(const struct npu_stream_config *d) {
  uint32_t rf_bytes = npu_regfile_bank_bytes() * 2;
  if (npu_read(NPU_STREAM_ABI) != NPU_STREAM_ABI_V1 || (npu_read(0x604) & (NPU_BUSY | NPU_ERROR)))
    return -1;
  if ((d->src & 3u) || !npu_data_span(d->src, 1, rf_bytes) ||
      !npu_data_span(d->weights, 1, rf_bytes) ||
      (!d->mode && ((d->dst & 3u) || !npu_data_span(d->dst, 4, rf_bytes))) ||
      d->partial < NPU_REGFILE_BASE || (d->partial & 3u) ||
      !npu_data_span(d->partial, 32, rf_bytes) || !d->row_stride || d->row_stride > 32767 ||
      !d->plane_stride || d->plane_stride > 32767 || !d->cin || d->cin > 256 ||
      (d->stride != 1 && d->stride != 2) || d->input_zero > 255 || d->mode != 0)
    return -1;
  npu_write(0x608, d->src);
  npu_write(0x60c, d->weights);
  npu_write(0x610, d->dst);
  npu_write(0x614, d->row_stride);
  npu_write(0x618, d->partial);
  npu_write(0x61c, d->cin);
  npu_write(0x620, d->stride);
  npu_write(0x624, d->plane_stride);
  npu_write(0x62c, d->input_zero);
  npu_write(0x630, d->mode);
  npu_fence();
  return 0;
}
static inline uint32_t npu_stream_task(unsigned co, unsigned y, unsigned x, unsigned count,
                                       unsigned rows, int left, int right, unsigned dst_words) {
  return (co & 15u) | ((y & 31u) << 4) | ((x & 31u) << 9) | ((count & 15u) << 14) |
         ((rows & 7u) << 18) | ((left != 0) << 21) | ((right != 0) << 22) |
         ((dst_words & 511u) << 23);
}
static inline int npu_stream_submit(uint32_t task) {
  unsigned count = (task >> 14) & 15u;
  if (!count || count > 8 || !npu_queue_has_space(NPU_CNN_QUEUE) || (npu_read(0x604) & NPU_ERROR))
    return -1;
  uint32_t before = npu_read(NPU_CNN_SUBMITTED);
  npu_write(0x628, task);
  npu_fence();
  npu_write(0x600, 1);
  return npu_read(NPU_CNN_SUBMITTED) == before + 1u ? 0 : -1;
}
/* Source-level compatibility adapter. The old binary CRW2 ABI is retired.
 * Full convolution shape, tensor ranges and partial-buffer aliasing are now
 * software checks; raw MMIO callers must enforce equivalent ownership rules. */
struct npu_cnn_descriptor {
  uint32_t src, weights, dst, width, height, cin, stride, output_width, output_row, input_zero, op;
};
static inline int npu_cnn_descriptor_valid(const struct npu_cnn_descriptor *d, uint32_t rf_bytes) {
  if (rf_bytes < 32 || d->op != 0 || !d->width || d->width > 28 || !d->height || d->height > 28 ||
      !d->cin || d->cin > 256 || (d->stride != 1 && d->stride != 2) || d->input_zero > 255 ||
      (d->src & 3u))
    return 0;
  if (!d->output_width || d->output_width > (d->width + d->stride - 1) / d->stride ||
      d->output_row >= (d->height + d->stride - 1) / d->stride)
    return 0;
  uint32_t inputs = d->width * d->height * d->cin, weights = d->cin * 9u,
           output = d->output_width * 4u;
  uint32_t partial = NPU_REGFILE_BASE + rf_bytes - 32;
  if (!npu_data_span(d->src, inputs, rf_bytes) || !npu_data_span(d->weights, weights, rf_bytes) ||
      npu_spans_overlap(partial, 32, d->src, inputs) ||
      npu_spans_overlap(partial, 32, d->weights, weights))
    return 0;
  return (!(d->dst & 3u) && npu_data_span(d->dst, output, rf_bytes) &&
          !npu_spans_overlap(d->dst, output, d->src, inputs) &&
          !npu_spans_overlap(d->dst, output, d->weights, weights) &&
          !npu_spans_overlap(d->dst, output, partial, 32));
}
static inline int npu_cnn_start(const struct npu_cnn_descriptor *d) {
  uint32_t bytes = npu_regfile_bank_bytes() * 2;
  /* Reserve every tile before submitting any part of this row. */
  if (!npu_cnn_descriptor_valid(d, bytes) ||
      (npu_read(NPU_CNN_QUEUE) >> 16) < (d->output_width + 7) / 8)
    return -1;
  struct npu_stream_config cfg = {d->src,
                                  d->weights,
                                  d->dst,
                                  d->width,
                                  NPU_REGFILE_BASE + bytes - 32,
                                  d->cin,
                                  d->stride,
                                  d->width * d->height,
                                  d->input_zero,
                                  d->op};
  if (npu_stream_configure(&cfg))
    return -1;
  unsigned mask = 0;
  for (int r = 0; r < 3; r++) {
    int y = (int)(d->output_row * d->stride) + r - 1;
    if (y >= 0 && y < (int)d->height)
      mask |= 1u << r;
  }
  for (unsigned x = 0; x < d->output_width; x += 8) {
    unsigned n = d->output_width - x > 8 ? 8 : d->output_width - x;
    if (npu_stream_submit(npu_stream_task(0, d->output_row, x, n, mask, x == 0,
                                          (x + n - 1) * d->stride + 1 >= d->width, x)))
      return -1;
  }
  return 0;
}
/* Blocking reference adapter. Optimized assembly batches commands per layer. */
static inline int npu_cnn_layer(struct npu_cnn_descriptor row, uint32_t channels, uint32_t rows,
                                uint32_t timeout) {
  uint32_t rf_bytes = npu_regfile_bank_bytes() * 2;
  if (!channels || channels > 16 || !rows || !npu_cnn_descriptor_valid(&row, rf_bytes) ||
      rows > (row.height + row.stride - 1) / row.stride)
    return -1;
  uint32_t inputs = row.width * row.height * row.cin;
  uint32_t weights = channels * row.cin * 9;
  uint32_t output = channels * rows * row.output_width * 4;
  uint32_t partial = NPU_REGFILE_BASE + rf_bytes - 32;
  /* Validate the entire layer before an early row can overwrite later inputs. */
  if (!npu_data_span(row.weights, weights, rf_bytes) ||
      npu_spans_overlap(partial, 32, row.weights, weights) ||
      (!row.op && (!npu_data_span(row.dst, output, rf_bytes) ||
                   npu_spans_overlap(row.dst, output, row.src, inputs) ||
                   npu_spans_overlap(row.dst, output, row.weights, weights) ||
                   npu_spans_overlap(row.dst, output, partial, 32))))
    return -1;
  for (uint32_t c = 0; c < channels; c++) {
    for (uint32_t y = 0; y < rows; y++) {
      row.output_row = y;
      int rc = npu_cnn_start(&row);
      if (rc)
        return rc;
      uint32_t ticket = npu_read(NPU_CNN_SUBMITTED), remaining = timeout;
      while ((int32_t)(npu_read(NPU_CNN_COMPLETED) - ticket) < 0) {
        if (npu_read(0x604) & NPU_ERROR)
          return -1;
        if (!remaining--)
          return -2;
      }
      row.dst += row.output_width * 4;
    }
    row.weights += row.cin * 9;
  }
  return 0;
}
/* RF compute gather: lanes[23:16], physical banks[15:8], bits/lane[7:0]. */
#define NPU_RF_GATHER_CAP 0x05cu
#endif
