#include "model_data.h"

/* CPU-in-loop host streaming test firmware.
 *
 * The host places one quantized image directly in the NPU SRAM through Debug
 * SBA and writes MAIL[0] with CMD_BASE + sample_index.  The CPU, through its
 * normal AXI data port, starts the NPU, services its IRQ, reads the ten output
 * bytes and publishes DONE_BASE + sample_index.  This keeps the host traffic
 * and CPU traffic concurrent on the real SoC crossbar.
 */
#define NPU ((volatile unsigned int *)0x70000000u)
#define SRAM ((volatile unsigned int *)0x70004000u)
#define MAIL ((volatile unsigned int *)0x80001fc0u)

#define CMD_BASE 0x53540000u
#define DONE_BASE 0x444f0000u
#ifndef STREAM_RUNS
#define STREAM_RUNS 1000u
#endif

static volatile unsigned int irq_count;

static void barrier(void) { __asm__ volatile ("fence iorw, iorw" ::: "memory"); }

static void fail(unsigned int code) {
    MAIL[1] = code;
    barrier();
    MAIL[0] = 0xdeadbeefu;
    for (;;) __asm__ volatile ("nop");
}

void __attribute__((interrupt("machine"), aligned(256))) npu_handler(void) {
    unsigned int cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x80000010u) fail(0x100u + cause);
    NPU[0] = 4u; /* clear DONE and disable interrupt */
    barrier();
    ++irq_count;
}

static void load_model(void) {
    for (unsigned int i = 0; i < sizeof(model_params) / 4; ++i)
        SRAM[i] = model_params[i];
    for (unsigned int i = 0; i < sizeof(model_desc) / 4; ++i)
        SRAM[DESC_BASE / 4 + i] = model_desc[i];
    barrier();
    NPU[4] = DESC_BASE;
    NPU[5] = 6u;
    barrier();
}

static void publish_output(unsigned int sample) {
    unsigned int best = 0;
    unsigned int bestval = 0;
    for (unsigned int i = 0; i < 10; ++i) {
        unsigned int word = SRAM[OUTPUT_BASE / 4 + i / 4];
        unsigned int q = (word >> ((i % 4) * 8)) & 255u;
        MAIL[4 + i] = q;
        if (i == 0 || q > bestval) {
            best = i;
            bestval = q;
        }
    }
    MAIL[2] = best;
    MAIL[3] = NPU[6];
    barrier();
    MAIL[0] = DONE_BASE + sample;
    barrier();
}

int main(void) {
    MAIL[0] = 0x5354524du; /* READY */
    load_model();

    unsigned int handler = (unsigned int)npu_handler;
    __asm__ volatile ("csrw mtvec, %0" :: "r"(handler));
    __asm__ volatile ("csrw mie, %0" :: "r"(1u << 16));
    __asm__ volatile ("csrsi mstatus, 8");

    for (unsigned int sample = 0; sample < STREAM_RUNS; ++sample) {
        unsigned int command;
        do {
            command = MAIL[0];
            __asm__ volatile ("nop");
        } while (command != CMD_BASE + sample);

        NPU[0] = 3u; /* start and enable completion IRQ */
        barrier();
        unsigned int limit = 2000000u;
        while (irq_count <= sample && limit--)
            __asm__ volatile ("nop");
        if (irq_count != sample + 1u)
            fail(0x200u + sample);
        publish_output(sample);
    }

    __asm__ volatile ("csrci mstatus, 8");
    MAIL[0] = 0xc0dec0deu;
    barrier();
    for (;;) __asm__ volatile ("nop");
}
