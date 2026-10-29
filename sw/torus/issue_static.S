.option norelax
.text
.global tor_fast_kernel
.type tor_fast_kernel,@function
tor_fast_kernel:
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
 li a0,0x3c00
 and t2,a3,a0
 li t1,0xf0000003
 or t2,t2,t1
 sw t2,0(t0)
 li t2,0xec000003
 sw t2,0(t0)
 and t2,a4,a0
 or t2,t2,t1
 sw t2,0(t0)
 // Input zero-point subtraction is an ordinary PE instruction.
 li t1,0x12100200
 or t1,t1,a2
 beqz a2,.Lplain
.macro center source
 and t2,\source,a0
 or t2,t2,t1
 sw t2,0(t0)
.endm
.Lcenter:
 center a3
 sw a3,0(t0)
 center a4
 sw a4,0(t0)
 center a5
 sw a5,0(t0)
 center a6
 sw a6,0(t0)
 center a7
 sw a7,0(t0)
 center t3
 sw t3,0(t0)
 center t4
 sw t4,0(t0)
 addi a1,a1,-1
 beqz a1,.Lcenter_tail
 center t5
 sw t5,0(t0)
 center t6
 sw t6,0(t0)
 j .Lcenter
.Lcenter_tail:
 center t5
 andi t2,t5,-129
 sw t2,0(t0)
 center t6
 andi t2,t6,-512
 sw t2,0(t0)
 ret
.Lplain:
 sw a3,0(t0)
 sw a4,0(t0)
 sw a5,0(t0)
 sw a6,0(t0)
 sw a7,0(t0)
 sw t3,0(t0)
 sw t4,0(t0)
 addi a1,a1,-1
 beqz a1,.Lplain_tail
 sw t5,0(t0)
 sw t6,0(t0)
 j .Lplain
.Lplain_tail:
 andi t2,t5,-129
 sw t2,0(t0)
 andi t2,t6,-512
 sw t2,0(t0)
 ret
.size tor_fast_kernel,.-tor_fast_kernel
.global tor_fast_linear
.type tor_fast_linear,@function
tor_fast_linear:
 li t0,0x70000ffc
 li t4,0x3c00
 and t2,a1,t4
 li t1,0xf0000003
 or t2,t2,t1
 sw t2,0(t0)
 li t3,0xec000003
 sw t3,0(t0)
 li t5,1
 beq a0,t5,.Llinear_last
 sw t2,0(t0)
 li t5,2
.Llinear:
 beq a0,t5,.Llinear_tail
 sw a1,0(t0)
 addi a0,a0,-1
 j .Llinear
.Llinear_tail:
 andi t2,a1,-129
 sw t2,0(t0)
.Llinear_last:
 andi t2,a1,-512
 sw t2,0(t0)
 ret
.size tor_fast_linear,.-tor_fast_linear
