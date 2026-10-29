#include "torus.h"
#include "torus_model.h"
#define MB ((volatile uint32_t*)0x80001fc0u)
#define SRAM8 ((volatile uint8_t*)0x80000000u)
static inline uint32_t cycle(void){uint32_t x;__asm__ volatile("csrr %0,mcycle":"=r"(x));return x;}
static void burst(void){
 uint32_t c=TOR_IMM(TOR_ADD,3,3,1,15);
 TOR_EMIT(TOR_IMM(TOR_MOVB,3,0,0,15));
 // Preload one native register and use 64 actual CPU stores, no command RAM.
 __asm__ volatile(".rept 64\n sw %0,0(%1)\n .endr"::"r"(c),"r"(0x70000ffcu):"memory");
 if(TOR_REG(0,3)!=64u){MB[1]=0xb001;MB[0]=0xdeadbeef;for(;;){}}
}
#ifndef TORUS_OVERLAP
#define TORUS_OVERLAP 1
#endif
#ifndef TORUS_COMPACT_CONFIG
#define TORUS_COMPACT_CONFIG 1
#endif
extern void tor_kernel(const uint32_t*next,unsigned channels,uint32_t subtract_delta);
extern void tor_linear(unsigned terms,uint32_t next,uint32_t subtract_delta);
static void configure_layer(const struct tor_layer*l,unsigned nr,unsigned nc){
 unsigned plane=l->oh*l->ow,k=l->fc?1:3;
 tor_desc(0,l->src,TOR_U8|TOR_ROW,nr,nc,l->fc?0:l->stride,0,
     k,k,l->ic,1,l->iw,l->fc?1:l->ih*l->iw,2,0);
 tor_desc(1,l->wb,TOR_S8|TOR_COL|TOR_NOFILL,nr,nc,0,1,
     k,k,l->ic,4,k*4,k*k*4,3,0);
 tor_desc(2,l->bb,TOR_RAW32|TOR_COL,nr,nc,0,4,2,1,1,l->mb-l->bb,0,0,4,0);
 tor_desc(3,l->dst,TOR_U8|TOR_STORE|TOR_TRANSPOSE,nr,nc,1,plane,1,1,1,0,0,0,0,0);
}
static void layer(const struct tor_layer*l){
 unsigned plane=l->oh*l->ow,terms=l->ic*(l->fc?1:9);
 unsigned last_shape=(l->ow<4?l->ow:4)|((l->oc<4?l->oc:4)<<4);
#if TORUS_COMPACT_CONFIG
 configure_layer(l,last_shape&15,last_shape>>4);
#endif
 for(unsigned co=0;co<l->oc;co+=4){
  unsigned nc=l->oc-co;if(nc>4)nc=4;
#if TORUS_COMPACT_CONFIG
  if(co){TOR_DESC(1)[0]=l->wb+(co/4)*terms*4;TOR_DESC(2)[0]=l->bb+co*4;}
#endif
  for(unsigned oy=0;oy<l->oh;oy++){
   int y=(int)(oy*l->stride)-(l->fc?0:1);
   unsigned ym0=(y>=0&&y<(int)l->ih)?15:0;
   unsigned ym1=(y+1>=0&&y+1<(int)l->ih)?15:0;
   unsigned ym2=(y+2>=0&&y+2<(int)l->ih)?15:0;
   for(unsigned ox=0;ox<l->ow;ox+=4){
    unsigned nr=l->ow-ox;if(nr>4)nr=4;unsigned rows=(1u<<nr)-1,shape=nr|(nc<<4);
    int x=(int)(ox*l->stride)-(l->fc?0:1);
#if TORUS_COMPACT_CONFIG
    if(shape!=last_shape){for(unsigned c=0;c<4;c++)TOR_DESC(c)[2]=shape;last_shape=shape;}
#else
    configure_layer(l,nr,nc);
    TOR_DESC(1)[0]=l->wb+(co/4)*terms*4;TOR_DESC(2)[0]=l->bb+co*4;
#endif
    TOR_DESC(0)[0]=l->src+y*l->iw+x;
    TOR_DESC(3)[0]=l->dst+co*plane+oy*l->ow+ox;
    TOR_EMIT(TOR_IO(TOR_ARM,15,0));
    TOR_EMIT(TOR_IO(TOR_NEXT,4,rows)); // bias -> R0
#if TORUS_COMPACT_CONFIG
    if(oy==0&&ox==0)
#endif
     TOR_EMIT(TOR_IO(TOR_NEXT,4,rows)); // R1 survives every spatial tile in this channel group
    unsigned op=TORUS_OVERLAP?TOR_EXCHANGE:TOR_NEXT;
    uint32_t delta=l->iz?(TOR_IMM(TOR_SUB,2,2,l->iz,0)^TOR_IO(op,3,0)):0;
    if(l->fc){
     tor_linear(l->ic,TOR_IO(op,3,rows),delta);
    }else{
     unsigned xm[3]={rows,rows,rows};
     if(x<0||x+(int)((nr-1)*l->stride)+2>=(int)l->iw){
      for(unsigned k=0;k<3;k++){
       xm[k]=0;for(unsigned r=0;r<nr;r++)if(x+(int)(k+r*l->stride)>=0&&x+(int)(k+r*l->stride)<(int)l->iw)xm[k]|=1u<<r;
      }
     }
     uint32_t next[9];unsigned base=TOR_IO(op,3,0);
     next[0]=base|((xm[0]&ym0)<<10);next[1]=base|((xm[1]&ym0)<<10);next[2]=base|((xm[2]&ym0)<<10);
     next[3]=base|((xm[0]&ym1)<<10);next[4]=base|((xm[1]&ym1)<<10);next[5]=base|((xm[2]&ym1)<<10);
     next[6]=base|((xm[0]&ym2)<<10);next[7]=base|((xm[1]&ym2)<<10);next[8]=base|((xm[2]&ym2)<<10);
     tor_kernel(next,l->ic,delta);
    }
    TOR_EMIT(TOR_CMD(TOR_MULHR,0,0,1,rows));
    if(l->oz)TOR_EMIT(TOR_IMM(TOR_ADD,0,0,l->oz,rows));
    TOR_EMIT(TOR_IMM(TOR_MAX,0,0,l->relu?l->oz:0,rows));
    TOR_EMIT(TOR_IMM(TOR_MIN,0,0,l->qmax,rows));
    TOR_EMIT(TOR_IO(TOR_NEXT,8,rows));
   }
  }
 }
 tor_wait();
}
int main(void){
 __asm__ volatile("csrw mcountinhibit,zero":::"memory");
 MB[1]=0;burst();MB[0]=0x544f5252;
 for(unsigned run=0;;run++){
  while(MB[0]!=(0x53540000u+run)){}
  unsigned control=MB[1],start=cycle();
  for(unsigned li=0;li<6;li++){
   MB[15]=li;layer(&tor_layers[li]);
   if(control&1)for(unsigned i=0;i<tor_sizes[li];i++)SRAM8[0x3800+tor_offsets[li]+i]=SRAM8[tor_layers[li].dst+i];
   if(control&(1u<<(li+8))){MB[0]=0x54415000u+li;while(MB[0]!=(0x53540000u+run)){}}
  }
  unsigned layer_end=cycle();
  unsigned best=0;for(unsigned i=1;i<10;i++)if(SRAM8[tor_layers[5].dst+i]>SRAM8[tor_layers[5].dst+best])best=i;
  unsigned total_end=cycle();MB[4]=layer_end-start;MB[3]=total_end-start;
  MB[2]=best;MB[1]=TOR_MMIO[1]&2;MB[0]=MB[1]?0xdeadbeef:0x444f0000u+run;
 }
}
