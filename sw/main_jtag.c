#include "jtag_layout.h"
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
    for(unsigned int i=1;i<16;i++)MAIL[i]=0;
    unsigned int handler=(unsigned int)npu_handler;
    __asm__ volatile("csrw mtvec, %0"::"r"(handler));
    __asm__ volatile("csrw mie, %0"::"r"(1u<<16));
    NPU[4]=DESC_BASE;NPU[5]=6u;MAIL[15]=BUILD_ID;barrier();
    MAIL[0]=0x5354524du;barrier();
    for(unsigned int seq=0;seq<65536;seq++){
        while(MAIL[0]!=0x53540000u+seq)__asm__ volatile("nop");
        // Local IRQ remains enabled; global MIE is masked across check/WFI.
        // CV32E40P wakes on the enabled pending IRQ, then services it on MIE=1.
        __asm__ volatile("csrci mstatus, 8");
        NPU[0]=3u;barrier();
        while(irq_count<=seq){
            __asm__ volatile("wfi");
            __asm__ volatile("csrsi mstatus, 8");
            __asm__ volatile("csrci mstatus, 8");
        }
        unsigned int words[3],best=0,bestval=0;
        for(unsigned int i=0;i<3;i++)words[i]=SRAM[OUTPUT_BASE/4+i];
        for(unsigned int i=0;i<10;i++){
            unsigned int q=(words[i/4]>>((i%4)*8))&255u;MAIL[4+i]=q;
            if(i==0||q>bestval){best=i;bestval=q;}
        }
        MAIL[2]=best;MAIL[3]=NPU[6];MAIL[14]=irq_count;barrier();
        MAIL[0]=0x444f0000u+seq;barrier();
    }
    for(;;)__asm__ volatile("nop");
}
