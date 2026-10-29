#ifndef TORUS_OVERLAP
#define TORUS_OVERLAP 1
#endif
// Native RV32 instructions fetched from shared SRAM. Nine command words are
// DATA in CPU registers, not a PE microprogram or an instruction register RAM.
.option norelax
.text
.global tor_kernel
.type tor_kernel,@function
tor_kernel:
 // Use caller-saved registers only: no spill/restore per spatial tile.
 lw a3,0(a0)
 lw a4,4(a0)
 lw a5,8(a0)
 lw a6,12(a0)
 lw a7,16(a0)
 lw t3,20(a0)
 lw t4,24(a0)
 lw t5,28(a0)
 lw t6,32(a0)
 li t0,0x70000ffc
#if TORUS_OVERLAP
 li t1,0xf010c003  // MAC9X8 XOR EXCHANGE
 li a0,0xec000003  // COMMIT(ctx0,ctx1)
 li t2,0x18000000  // PREFETCH XOR EXCHANGE
 xor t2,a3,t2
 sw t2,0(t0)       // prefetch first term
 sw a0,0(t0)       // publish first term
 li t2,0x18000000
 xor t2,a4,t2
 sw t2,0(t0)       // prefetch second term before computing first
#else
 li t1,0xe010c003  // MAC9X8 XOR NEXT
#endif
 beqz a2,.Lplain
.macro mac source,center
 .if \center
 xor t2,\source,a2
 sw t2,0(t0)
 .endif
 xor t2,\source,t1
 sw t2,0(t0)
.endm
.Lzero_point:
#if TORUS_OVERLAP
 mac a3,1
 sw a5,0(t0)
 mac a4,1
 sw a6,0(t0)
 mac a5,1
 sw a7,0(t0)
 mac a6,1
 sw t3,0(t0)
 mac a7,1
 sw t4,0(t0)
 mac t3,1
 sw t5,0(t0)
 mac t4,1
 sw t6,0(t0)
 mac t5,1
 addi a1,a1,-1
 beqz a1,.Lzero_point_last
 sw a3,0(t0)       // commit term8, prefetch next channel's term0
 mac t6,1
 sw a4,0(t0)       // commit term0, prefetch term1
 j .Lzero_point
.Lzero_point_last:
 sw a0,0(t0)       // drain; never prefetch past shape end
 mac t6,1
 j .Lreturn
#else
 sw a3,0(t0)
 mac a3,1
 sw a4,0(t0)
 mac a4,1
 sw a5,0(t0)
 mac a5,1
 sw a6,0(t0)
 mac a6,1
 sw a7,0(t0)
 mac a7,1
 sw t3,0(t0)
 mac t3,1
 sw t4,0(t0)
 mac t4,1
 sw t5,0(t0)
 mac t5,1
 sw t6,0(t0)
 mac t6,1
 addi a1,a1,-1
 bnez a1,.Lzero_point
 j .Lreturn
#endif
.Lplain:
#if TORUS_OVERLAP
 mac a3,0
 sw a5,0(t0)
 mac a4,0
 sw a6,0(t0)
 mac a5,0
 sw a7,0(t0)
 mac a6,0
 sw t3,0(t0)
 mac a7,0
 sw t4,0(t0)
 mac t3,0
 sw t5,0(t0)
 mac t4,0
 sw t6,0(t0)
 mac t5,0
 addi a1,a1,-1
 beqz a1,.Lplain_last
 sw a3,0(t0)       // commit term8, prefetch next channel's term0
 mac t6,0
 sw a4,0(t0)       // commit term0, prefetch term1
 j .Lplain
.Lplain_last:
 sw a0,0(t0)       // drain; never prefetch past shape end
 mac t6,0
 j .Lreturn
#else
 sw a3,0(t0)
 mac a3,0
 sw a4,0(t0)
 mac a4,0
 sw a5,0(t0)
 mac a5,0
 sw a6,0(t0)
 mac a6,0
 sw a7,0(t0)
 mac a7,0
 sw t3,0(t0)
 mac t3,0
 sw t4,0(t0)
 mac t4,0
 sw t5,0(t0)
 mac t5,0
 sw t6,0(t0)
 mac t6,0
 addi a1,a1,-1
 bnez a1,.Lplain
 j .Lreturn
#endif
.Lreturn:
 ret
.size tor_kernel,.-tor_kernel

.global tor_linear
.type tor_linear,@function
tor_linear:
 li t0,0x70000ffc
#if TORUS_OVERLAP
 li t1,0xf010c003
 li t3,0xec000003
 li t4,0x18000000
 xor t2,a1,t4
 sw t2,0(t0)
 sw t3,0(t0)
 li t5,1
 beq a0,t5,.Llinear_last
 sw t2,0(t0)
#else
 li t1,0xe010c003
#endif
.Llinear:
#if !TORUS_OVERLAP
 sw a1,0(t0)
#endif
 beqz a2,.Llinear_mac
 xor t2,a1,a2
 sw t2,0(t0)
.Llinear_mac:
 xor t2,a1,t1
 sw t2,0(t0)
 addi a0,a0,-1
#if TORUS_OVERLAP
 beq a0,t5,.Llinear_drain
 sw a1,0(t0)
#else
 beqz a0,.Llinear_return
#endif
 j .Llinear
#if TORUS_OVERLAP
.Llinear_drain:
 sw t3,0(t0)
.Llinear_last:
 beqz a2,.Llinear_last_mac
 xor t2,a1,a2
 sw t2,0(t0)
.Llinear_last_mac:
 xor t2,a1,t1
 sw t2,0(t0)
#endif
.Llinear_return:
 ret
.size tor_linear,.-tor_linear
