.option norelax
.text
.global tor_native_layer
.type tor_native_layer,@function
// One generic native RV32 layer driver. Metadata/programs live in CPU SRAM.
// All loops, padding choices, arithmetic and stream words are software-issued.
tor_native_layer:
 addi sp,sp,-64
 sw ra,48(sp)
 sw s0,0(sp)
 sw s1,4(sp)
 sw s2,8(sp)
 sw s3,12(sp)
 sw s4,16(sp)
 sw s5,20(sp)
 sw s6,24(sp)
 sw s7,28(sp)
 sw s8,32(sp)
 sw s9,36(sp)
 sw s10,40(sp)
 sw s11,44(sp)
 mv t3,a0
 mv s8,a1
 li s4,0x70000000
 li s0,0x70000ffc
 lw s2,0(t3)
 lw s3,4(t3)
 lw s9,8(t3)
 lw t5,12(t3)
 lw s10,20(t3)
 beqz s10,.Lno_oz
 li t2,0x0c000200
 or s10,s10,t2
.Lno_oz:
 lw s11,24(t3)
 li t2,0x38000200
 or s11,s11,t2
 lw t4,28(t3)
 li t2,0x34000200
 or t4,t4,t2
 beqz t5,.Lno_center
 li t2,0x12100200
 or t5,t5,t2
.Lno_center:
 lw t2,32(t3)
 jalr ra,t2,0
 li t3,0xf8000004
 li s7,-1
 li t6,0x3c00
 li t1,0xf0000003
.Ltile:
 lw s6,8(s2)
 srli s5,s6,12
 andi s5,s5,15
 slli s5,s5,10
 andi t2,s6,1536
 bnez t2,.Lnew_group
.Lgroup_ready:
.Lsame_shape:
 lw t0,0(s2)
 sw t0,0(s0)       // generic BASEPAIR patches two bases and resets context cursors
 or t0,t3,s5
 sw t0,0(s0)
 andi t2,s6,256
 bnez t2,.Lload_scale
.Lsame_scale:
 andi t2,s6,128
 bnez t2,.Lleft_bias
.Lbias_ready:
 bgez s9,.Lfc
 srli t2,s6,16
 beq t2,s7,.Lsame_pattern
 mv s7,t2
 slli t0,t2,6
 add t0,t0,s8
 jalr ra,t0,0
.Lsame_pattern:
 addi t2,t3,-1         // NEXT first operands: no separate prefetch/commit prime
 and t0,s1,t6
 or t0,t0,t2
 sw t0,0(s0)
 and t0,a0,t6
 or t0,t0,t1
 sw t0,0(s0)
 jr s9                 // compiler chooses entry for the channel count
.macro center source
 and t0,\source,t6
 or t0,t0,t5
 sw t0,0(s0)
.endm
#if TORUS_HAS_CENTER
.global tor_ci_center7
tor_ci_center7:
 center s1
 sw s1,0(s0)
 center a0
 sw a0,0(s0)
 center a1
 sw a1,0(s0)
 center a2
 sw a2,0(s0)
 center a3
 sw a3,0(s0)
 center a4
 sw a4,0(s0)
 center a5
 sw a5,0(s0)
 center a6
 andi t0,a6,-129
 sw t0,0(s0)
 center a7
 andi t0,a7,-512
 sw t0,0(s0)
 j .Lquant
#endif
.global tor_ci_plain0
tor_ci_plain0:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain1
tor_ci_plain1:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain2
tor_ci_plain2:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain3
tor_ci_plain3:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain4
tor_ci_plain4:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain5
tor_ci_plain5:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain6
tor_ci_plain6:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 sw a6,0(s0)
 sw a7,0(s0)
 .2byte 0x0001          // 24-byte native code slot
.global tor_ci_plain7
tor_ci_plain7:
 sw s1,0(s0)
 sw a0,0(s0)
 sw a1,0(s0)
 sw a2,0(s0)
 sw a3,0(s0)
 sw a4,0(s0)
 sw a5,0(s0)
 andi t0,a6,-129
 sw t0,0(s0)
 andi t0,a7,-512
 sw t0,0(s0)
 j .Lquant
.Lfc:
 mv a6,s9
 li s1,0x1810c1c0
 or s1,s1,s5
 srli t2,s5,10
 or s1,s1,t2
 li t0,0xf0000003
 or t0,t0,s5
 sw t0,0(s0)
 li t2,0xec000003
 sw t2,0(s0)
 li t2,1
 beq a6,t2,.Lfc_last
 sw t0,0(s0)
 li t2,8
.Lfc_block:
 bleu a6,t2,.Lfc_tail_loop
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 sw s1,0(s0)
 addi a6,a6,-8
 j .Lfc_block
.Lfc_tail_loop:
 li t2,2
 beq a6,t2,.Lfc_tail
 sw s1,0(s0)
 addi a6,a6,-1
 j .Lfc_tail_loop
.Lfc_tail:
 andi t0,s1,-129
 sw t0,0(s0)
.Lfc_last:
 andi t0,s1,-512
 sw t0,0(s0)
.Lquant:
 li t0,0xcc004000
 or t0,t0,s5
 sw t0,0(s0)
 beqz s10,.Lno_add
 or t0,s10,s5
 sw t0,0(s0)
.Lno_add:
 or t0,s11,s5
 sw t0,0(s0)
 or t0,t4,s5
 sw t0,0(s0)
 li t0,0xf8000008
 or t0,t0,s5
 sw t0,0(s0)
 addi s2,s2,12
 addi s3,s3,-1
 bnez s3,.Ltile
 j .Lwait
.Lnew_group:
 andi t2,s6,512
 beqz t2,.Lnew_shape
 lw t0,4(s2)
 slli t2,t0,16
 srli t2,t2,16
 sw t2,0x500(s4)
 srli t0,t0,16
 sw t0,0x600(s4)
.Lnew_shape:
 andi t2,s6,1024
 beqz t2,.Lgroup_ready
 andi t0,s6,112
 ori t0,t0,4
 sw t0,0x708(s4)
 j .Lgroup_ready
.Lload_scale:
 sw t0,0(s0)
 j .Lsame_scale
.Lleft_bias:
 lw t0,4(s2)
 srli t0,t0,16
 lui t2,0x80000
 add t0,t0,t2
 lw t2,8(t0)
 sw t2,0x100(s4)
 lw t2,12(t0)
 sw t2,0x110(s4)
 j .Lbias_ready
.Lwait:
 lw t0,4(s4)
 andi t0,t0,1
 bnez t0,.Lwait
 lw s0,0(sp)
 lw s1,4(sp)
 lw s2,8(sp)
 lw s3,12(sp)
 lw s4,16(sp)
 lw s5,20(sp)
 lw s6,24(sp)
 lw s7,28(sp)
 lw s8,32(sp)
 lw s9,36(sp)
 lw s10,40(sp)
 lw s11,44(sp)
 lw ra,48(sp)
 addi sp,sp,64
 ret
.size tor_native_layer,.-tor_native_layer
