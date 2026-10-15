#include "model_data.h"
#define NPU ((volatile unsigned int*)0x70000000u)
#define SRAM ((volatile unsigned int*)0x70004000u)
#define MAIL ((volatile unsigned int*)0x80001fc0u)
static volatile unsigned int irq_count;
static void barrier(void){__asm__ volatile("fence iorw, iorw":::"memory");}
static void fail(unsigned int code){MAIL[1]=code;barrier();MAIL[0]=0xdeadbeefu;for(;;)__asm__ volatile("nop");}
void __attribute__((interrupt("machine"),aligned(256))) npu_handler(void){
    unsigned int cause;__asm__ volatile("csrr %0, mcause":"=r"(cause));
    if(cause!=0x80000010u)fail(0x100u+cause);
    unsigned int status=NPU[1];
    NPU[0]=4u;barrier();
    if((status&6u)!=2u)fail(0x200u+status);
    ++irq_count;
}
int main(void){
    unsigned int handler=(unsigned int)npu_handler;
    __asm__ volatile("csrw mtvec, %0"::"r"(handler));
    __asm__ volatile("csrw mie, %0"::"r"(1u<<16));
    NPU[4]=DESC_BASE;NPU[5]=6u;barrier();
#ifdef HOST_STREAM
    MAIL[0]=0x5354524du;barrier();
    const unsigned int runs=1000;
#else
    const unsigned int runs=5;
#endif
    for(unsigned int run=0;run<runs;run++){
#ifdef HOST_STREAM
        while(MAIL[0]!=0x53540000u+run)__asm__ volatile("nop");
#else
        for(unsigned int i=0;i<196;i++)SRAM[INPUT_BASE/4+i]=model_input[i];
#endif
        /* Mask globally while testing irq_count and entering WFI. The local
         * enabled IRQ wakes CV32E40P even with MIE=0; pending IRQ then traps
         * when MIE is set. This closes the check-before-WFI lost-wakeup race. */
        __asm__ volatile("csrci mstatus, 8");
        NPU[0]=3u;barrier();
        while(irq_count<=run){
            __asm__ volatile("wfi");
            __asm__ volatile("csrsi mstatus, 8");
            __asm__ volatile("csrci mstatus, 8");
        }
        unsigned int best=0,bestval=0,words[3];
        for(unsigned int i=0;i<3;i++)words[i]=SRAM[OUTPUT_BASE/4+i];
        for(unsigned int i=0;i<10;i++){
            unsigned int q=(words[i/4]>>((i%4)*8))&255u;MAIL[4+i]=q;
#ifndef HOST_STREAM
            if(q!=integer_output[i])fail(0x300u+i);
#endif
            if(i==0||q>bestval){best=i;bestval=q;}
        }
        MAIL[2]=best;MAIL[3]=NPU[6];MAIL[14]=irq_count;barrier();
#ifdef HOST_STREAM
        MAIL[0]=0x444f0000u+run;barrier();
#endif
    }
    MAIL[0]=0xc0dec0deu;barrier();for(;;)__asm__ volatile("nop");
}
