#ifndef NPU_H
#define NPU_H
#include <stdint.h>
#define NPU_SRAM_BASE 0x80000000u
#define NPU_SRAM_BYTES 8192u
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
static inline void npu_fence(void) {
    __asm__ volatile ("fence rw, rw" ::: "memory");
}
/* Returns 0 on completion, -1 on command error, -2 on timeout. */
static inline int npu_wait(uint32_t status_offset, uint32_t timeout) {
    while (timeout--) {
        uint32_t s = npu_read(status_offset);
        if (s & NPU_ERROR) return -1;
        if ((s & (NPU_BUSY | NPU_DONE)) == NPU_DONE) {
            npu_fence();
            return 0;
        }
    }
    return -2;
}
/* Nonblocking launch; no writes allowed while the same unit is busy. */
static inline int npu_matmul_start(uint32_t a, uint32_t b, uint32_t d,
                                  uint32_t m, uint32_t n, uint32_t k) {
    if (npu_read(0x104) & NPU_BUSY) return -1;
    npu_write(0x108,a); npu_write(0x10c,b); npu_write(0x110,d);
    npu_write(0x114,m); npu_write(0x118,n); npu_write(0x11c,k);
    npu_fence(); npu_write(0x100,1);
    return (npu_read(0x104) & NPU_ERROR) ? -1 : 0;
}
static inline int npu_vector_start(uint32_t a, uint32_t b, uint32_t d,
                                  uint32_t len, uint32_t op) {
    if (npu_read(0x204) & NPU_BUSY) return -1;
    npu_write(0x208,a); npu_write(0x218,b); npu_write(0x20c,d);
    npu_write(0x210,len); npu_write(0x214,op);
    npu_fence(); npu_write(0x200,1);
    return (npu_read(0x204) & NPU_ERROR) ? -1 : 0;
}
#define NPU_CPU_CONTROL 0x008u
#define NPU_CPU_BOOT_ADDR 0x00cu
#define NPU_DMA_RX 0x300u
#define NPU_DMA_TX 0x400u
#define NPU_DMA_MEM 0x500u
#define NPU_DMA_INGRESS 0u
#define NPU_DMA_EGRESS 1u
#define NPU_DMA_COPY 2u
#define NPU_DMA_FILL 3u
struct npu_dma_descriptor {
    uint32_t src, dst, row_bytes, rows, src_stride, dst_stride, mode, fill, timeout;
};
/* Write descriptors only when idle. Submitters must serialize CSR programming. */
static inline int npu_dma_start(uint32_t channel_base,
                               const struct npu_dma_descriptor *d) {
    if (npu_read(channel_base+4) & NPU_BUSY) return -1;
    npu_write(channel_base+8,d->src); npu_write(channel_base+12,d->dst);
    npu_write(channel_base+16,d->row_bytes); npu_write(channel_base+20,d->rows);
    npu_write(channel_base+24,d->src_stride); npu_write(channel_base+28,d->dst_stride);
    npu_write(channel_base+32,d->mode); npu_write(channel_base+36,d->fill);
    npu_write(channel_base+52,d->timeout);
    npu_fence(); npu_write(channel_base,1);
    return (npu_read(channel_base+4) & NPU_ERROR) ? -1 : 0;
}
static inline void npu_dma_abort(uint32_t channel_base) {
    npu_write(channel_base,4);
}
/* Packed UINT8 activations / INT8 weights, per-channel Q24 {M,B} pairs.
 * output dimensions can crop the bottom/right of a padded convolution.
 * op=0: 3x3 convolution + ReLU; op=1: FC (width=features, h=cin=ow=oh=1).
 */
struct npu_cnn_descriptor {
    uint32_t src, weights, quant, dst, width, height, cin, cout;
    uint32_t stride, output_width, output_height, input_zero, output_zero, op;
};
static inline int npu_cnn_start(const struct npu_cnn_descriptor *d) {
    if ((npu_read(0x604) | npu_read(0x104)) & NPU_BUSY) return -1;
    const uint32_t *fields = (const uint32_t *)d;
    for (unsigned i=0; i<14; ++i) npu_write(0x608+4*i,fields[i]);
    npu_fence(); npu_write(0x600,1);
    return (npu_read(0x604) & NPU_ERROR) ? -1 : 0;
}
/* CNN counters reset on each accepted valid launch. Useful MAC excludes padding.
 * irq_o[0]/CPU IRQ16 is shared by matrix completion and CNN done/error.
 * A WFI caller enables mie[16]; demos leave mstatus.MIE=0 so wake-up resumes
 * the following instruction without entering a trap handler.
 */
#define NPU_CNN_CYCLES 0x640u
#define NPU_CNN_MAC_CYCLES 0x644u
#define NPU_CNN_ISSUED 0x648u
#define NPU_CNN_MEMORY_TRANSACTIONS 0x64cu
#define NPU_CNN_WAIT_CYCLES 0x650u
/* Optional identical-node NoC. NoC IRQ21, short packet ACKs, native NMC DMA.
 * Caller owns local source/destination buffers until completion.
 * Watchdog quarantine requires a quiescent fabric reset, not automatic retry.
 */
#define NPU_NOC 0x700u
#define NPU_NOC_WRITE 1u
#define NPU_NOC_READ 2u
#define NPU_NOC_QUARANTINED 8u
struct npu_noc_descriptor {
    uint32_t destination_x, destination_y, op, remote_addr, local_addr, bytes, watchdog;
};
static inline int npu_noc_start(const struct npu_noc_descriptor *d) {
    if (npu_read(NPU_NOC+4) & (NPU_BUSY|NPU_NOC_QUARANTINED)) return -1;
    if (d->destination_x>15 || d->destination_y>15 ||
        (d->op!=NPU_NOC_WRITE && d->op!=NPU_NOC_READ)) return -1;
    npu_fence();
    npu_write(NPU_NOC+8,(d->op<<8)|(d->destination_y<<4)|d->destination_x);
    npu_write(NPU_NOC+12,d->remote_addr);npu_write(NPU_NOC+16,d->bytes);
    npu_write(NPU_NOC+20,d->local_addr);npu_write(NPU_NOC+24,d->watchdog);
    npu_write(NPU_NOC,1);
    return (npu_read(NPU_NOC+4) & NPU_ERROR) ? -1 : 0;
}
#endif
