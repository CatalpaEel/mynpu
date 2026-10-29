#ifndef MYNPU_TORUS_H
#define MYNPU_TORUS_H
#include <stdint.h>
// An operand selects LOCAL/NORTH/SOUTH/WEST/EAST and that PE's R0..R3.
// The destination is always a register of the executing PE.
enum { TOR_LOCAL=0, TOR_N=1, TOR_S=2, TOR_W=3, TOR_E=4 };
enum {
 TOR_HOLD=0,TOR_MOV=1,TOR_MOVB=2,TOR_ADD=3,TOR_SUB=4,TOR_MUL9X8=5,TOR_MAC9X8=6,
 TOR_AND=7,TOR_OR=8,TOR_XOR=9,TOR_SHL=10,TOR_SHR=11,TOR_SAR=12,TOR_MIN=13,TOR_MAX=14,
 TOR_LT=15,TOR_LTU=16,TOR_ADDSELF=17,TOR_ABS=18,TOR_NEG=19,TOR_NOT=20,
 TOR_MUL8=21,TOR_MAC8=22,TOR_MUL16=23,TOR_MAC16=24,TOR_MUL32=25,TOR_MAC32=26,
 TOR_MULH=27,TOR_MINU=28,TOR_MAXU=29,TOR_EQ=30,TOR_NE=31,TOR_LE=32,TOR_LEU=33,
 TOR_SEXT8=34,TOR_SEXT16=35,TOR_ZEXT8=36,TOR_ZEXT16=37,TOR_ROL=38,TOR_ROR=39,
 TOR_CLZ=40,TOR_CTZ=41,TOR_POPCNT=42,TOR_SAR_ROUND=43,TOR_SAT8=44,TOR_SAT16=45,
 TOR_SATU8=46,TOR_SATU16=47,TOR_SELECT=48,TOR_MULU8=49,TOR_MULU16=50,
 TOR_MULHR=51,TOR_CLIPU=52,TOR_BASEPAIR=53,TOR_EXCHANGE=58,TOR_COMMIT=59,TOR_PREFETCH=60,TOR_ARM=61,TOR_NEXT=62
};
#define TOR_SRC(direction,reg) (((direction)<<2)|(reg))
#define TOR_CMD(op,dst,a,b,mask) (((uint32_t)(op)<<26)|((uint32_t)(dst)<<24)|((uint32_t)(a)<<19)|((uint32_t)(b)<<14)|((uint32_t)(mask)<<10))
#define TOR_IMM(op,dst,a,imm,mask) (TOR_CMD(op,dst,a,0,mask)|0x200u|((uint32_t)(imm)&0x1ffu))
#define TOR_IO(op,contexts,rows) (TOR_CMD(op,0,0,0,rows)|((contexts)&15u))
// Register-format low bits: 8=bundle, 7=start next prefetch, 6:4=context code,
// 3:0=NEXT prefetch row mask. Arithmetic row mask remains 13:10.
// Context codes: 0..3 single; 4={0,1},5={0,3},6={2,1},7={2,3}.
#define TOR_BUNDLE(op,dst,a,b,rows,ctx,nextrows,advance) (TOR_CMD(op,dst,a,b,rows)|0x100u|((uint32_t)(advance)<<7)|((uint32_t)(ctx)<<4)|(nextrows))
#define TOR_MMIO ((volatile uint32_t*)0x70000000u)
#define TOR_EMIT(command) (TOR_MMIO[0xffc/4]=(uint32_t)(command))
#define TOR_REG(pe,reg) (TOR_MMIO[(0x100+(pe)*16+(reg)*4)/4])
#define TOR_DESC(context) (TOR_MMIO+(0x400+(context)*0x100)/4)
enum { TOR_U8=0,TOR_S8=1,TOR_U16=2,TOR_S16=3,TOR_RAW32=4,
       TOR_STORE=8,TOR_FULL=0,TOR_ROW=16,TOR_COL=32,TOR_TRANSPOSE=64,
       TOR_CYCLIC=256,TOR_NOFILL=512 };
// All strides are SIGNED BYTE strides; axis 0 is innermost.
// reg_steps: base[1:0], axis0[3:2], axis1[5:4], axis2[7:6], modulo four.
static inline void tor_desc(unsigned c,uint32_t base,uint32_t ctl,unsigned rows,unsigned cols,
 int32_t row_stride,int32_t col_stride,unsigned n0,unsigned n1,unsigned n2,
 int32_t s0,int32_t s1,int32_t s2,unsigned reg_steps,unsigned origin) {
 volatile uint32_t*d=TOR_DESC(c);
 d[0]=base;d[1]=ctl;d[2]=rows|(cols<<4);d[3]=row_stride;d[4]=col_stride;
 d[5]=n0;d[6]=n1;d[7]=n2;d[8]=s0;d[9]=s1;d[10]=s2;d[11]=reg_steps;d[12]=origin;
}
static inline void tor_wait(void) { while(TOR_MMIO[1]&1){} }
#endif
