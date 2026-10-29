#include "torus.h"
#include "torus_model.h"
#include "torus_static.h"
#define MB ((volatile uint32_t*)0x80001fc0u)
#define SRAM8 ((volatile uint8_t*)0x80000000u)
static inline uint32_t cycle(void){uint32_t x;__asm__ volatile("csrr %0,mcycle":"=r"(x));return x;}
#ifndef TORUS_NATIVE_DRIVER
#define TORUS_NATIVE_DRIVER 1
#endif
extern void tor_native_layer(const struct tor_static_layer*,const uint32_t*);
extern void tor_fast_kernel(const uint32_t*,unsigned,unsigned);
extern void tor_fast_linear(unsigned,uint32_t);

int main(void){
 __asm__ volatile("csrw mcountinhibit,zero":::"memory");
 uint32_t c=TOR_IMM(TOR_ADD,3,3,1,15);TOR_EMIT(TOR_IMM(TOR_MOVB,3,0,0,15));
 __asm__ volatile(".rept 64\n sw %0,0(%1)\n .endr"::"r"(c),"r"(0x70000ffcu):"memory");
 if(TOR_REG(0,3)!=64u){MB[1]=0xb001;MB[0]=0xdeadbeef;for(;;){}}
 MB[1]=0;MB[0]=0x544f5252;
 for(unsigned run=0;;run++){
  while(MB[0]!=0x53540000u+run){}
  unsigned control=MB[1],start=cycle();
  for(unsigned li=0;li<6;li++){
   MB[15]=li;
#if TORUS_NATIVE_DRIVER
   tor_native_layer(&tor_static_layers[li],(const uint32_t*)tor_pattern_code);
#else
   tor_native_layer(&tor_static_layers[li],(const uint32_t*)tor_pattern_code);
#endif
   if(control&1)for(unsigned i=0;i<tor_sizes[li];i++)SRAM8[0x3800+tor_offsets[li]+i]=SRAM8[tor_outputs[li]+i];
   if(control&(1u<<(li+8))){MB[0]=0x54415000u+li;while(MB[0]!=0x53540000u+run){}}
  }
  unsigned layer_end=cycle(),best=0;
  for(unsigned i=1;i<10;i++)if(SRAM8[tor_outputs[5]+i]>SRAM8[tor_outputs[5]+best])best=i;
  unsigned total_end=cycle();MB[4]=layer_end-start;MB[3]=total_end-start;
  MB[2]=best;MB[1]=TOR_MMIO[1]&2;MB[0]=MB[1]?0xdeadbeef:0x444f0000u+run;
 }
}
