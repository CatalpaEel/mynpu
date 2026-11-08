_start:
    lui x5, 0x70
    addi x5, x5, 0
    csrw mie,x5
    csrci mstatus,8
    lui x6, 0x40000
    addi x6, x6, 1536
    lw x8, -1456(x6)
    andi x8, x8, 511
    addi x5, x0, 32
    bne x8, x5, fail
    lw x8, -1448(x6)
    lui x5, 0x56504
    addi x5, x5, 1843
    bne x8, x5, fail
    lw x8, -1428(x6)
    lui x5, 0x40
    addi x5, x5, 1028
    bne x8, x5, fail
    lw x8, -1424(x6)
    lui x5, 0x70
    addi x5, x5, 0
    bne x8, x5, fail
    lw x8, 84(x6)
    lui x5, 0x53444
    addi x5, x5, -1739
    bne x8, x5, fail
    lui x7, 0x80001
    addi x7, x7, -768
    lui x12, 0x80002
    addi x12, x12, -256
    lw x8, 0(x7)
    sw x8, 8(x6)
    lw x8, 16(x7)
    sw x8, 20(x6)
    lw x8, 24(x7)
    sw x8, 28(x6)
    lw x8, 32(x7)
    sw x8, 32(x6)
    lw x8, 44(x7)
    sw x8, 44(x6)
    lui x8, 0x80004
    addi x8, x8, 200
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    addi x8, x0, 784
    sw x8, 36(x6)
    addi x8, x0, 0
    sw x8, 48(x6)
    lw x9, 4(x7)
    lui x10, 0x80004
    addi x10, x10, 0
    addi x11, x0, 5
weight_cache0:
    lw x8, 0(x9)
    sw x8, 0(x10)
    addi x9, x9, 4
    addi x10, x10, 4
    addi x11, x11, -1
    bne x11, x0, weight_cache0
    addi x31, x0, 1
    lw x1, 28(x7)
    lw x16, 8(x7)
    lw x17, 12(x7)
    lui x15, 0x80001
    addi x15, x15, -432
    addi x2, x0, 14
    lui x18, 0x80004
    addi x18, x18, 0
    lui x30, 0x40000
    addi x30, x30, 1792
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 0
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
    sw x0, 28(x30)
qchannel0:
    sw x18, 12(x6)
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    addi x3, x0, 0
qrow0:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
qspace0:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, qsubmit0
    jal x0, qspace0
qsubmit0:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, qrow0
    lw x5, 96(x6)
qdrain0:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 92(x6)
    bne x8, x5, qdrain0_sleep
    jal x0, qdrain0_done
qdrain0_sleep:
    wfi
    jal x0, qdrain0
qdrain0_done:
    addi x8, x0, 8
    sw x8, 0(x6)
    addi x8, x0, 196
    alu
    addi x16, x16, 8
    addi x18, x18, 9
    addi x1, x1, -1
    bne x1, x0, qchannel0
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x13, x0, 1
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack0
    jal x0, acked0
ack0:
    lw x8, 8(x12)
    bne x8, x13, ack0
acked0:
    lw x8, 56(x7)
    sw x8, 8(x6)
    lw x8, 72(x7)
    sw x8, 20(x6)
    lw x8, 80(x7)
    sw x8, 28(x6)
    lw x8, 88(x7)
    sw x8, 32(x6)
    lw x8, 100(x7)
    sw x8, 44(x6)
    lui x8, 0x80004
    addi x8, x8, 200
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    addi x8, x0, 196
    sw x8, 36(x6)
    addi x8, x0, 0
    sw x8, 48(x6)
    lw x9, 60(x7)
    lui x10, 0x80004
    addi x10, x10, 0
    addi x11, x0, 18
weight_cache1:
    lw x8, 0(x9)
    sw x8, 0(x10)
    addi x9, x9, 4
    addi x10, x10, 4
    addi x11, x11, -1
    bne x11, x0, weight_cache1
    addi x31, x0, 1
    lw x1, 84(x7)
    lw x16, 64(x7)
    lw x17, 68(x7)
    lui x15, 0x80001
    addi x15, x15, -320
    addi x2, x0, 14
    lui x18, 0x80004
    addi x18, x18, 0
    lui x30, 0x40000
    addi x30, x30, 1792
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 0
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
    sw x0, 28(x30)
qchannel1:
    sw x18, 12(x6)
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    addi x3, x0, 0
qrow1:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
qspace1:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, qsubmit1
    jal x0, qspace1
qsubmit1:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, qrow1
    lw x5, 96(x6)
qdrain1:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 92(x6)
    bne x8, x5, qdrain1_sleep
    jal x0, qdrain1_done
qdrain1_sleep:
    wfi
    jal x0, qdrain1
qdrain1_done:
    addi x8, x0, 8
    sw x8, 0(x6)
    addi x8, x0, 196
    alu
    addi x16, x16, 8
    addi x18, x18, 18
    addi x1, x1, -1
    bne x1, x0, qchannel1
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x13, x0, 2
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack1
    jal x0, acked1
ack1:
    lw x8, 8(x12)
    bne x8, x13, ack1
acked1:
    lw x8, 112(x7)
    sw x8, 8(x6)
    lw x8, 128(x7)
    sw x8, 20(x6)
    lw x8, 136(x7)
    sw x8, 28(x6)
    lw x8, 144(x7)
    sw x8, 32(x6)
    lw x8, 156(x7)
    sw x8, 44(x6)
    lui x8, 0x80004
    addi x8, x8, 228
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    addi x8, x0, 196
    sw x8, 36(x6)
    addi x8, x0, 0
    sw x8, 48(x6)
    addi x31, x0, 1
    lw x1, 140(x7)
    lw x16, 120(x7)
    lw x17, 124(x7)
    lui x15, 0x80001
    addi x15, x15, -96
    addi x2, x0, 7
    lw x18, 116(x7)
    lui x30, 0x40000
    addi x30, x30, 1792
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 0
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
    sw x0, 28(x30)
qchannel2:
    sw x18, 12(x6)
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    addi x3, x0, 0
qrow2:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
qspace2:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, qsubmit2
    jal x0, qspace2
qsubmit2:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, qrow2
    lw x5, 96(x6)
qdrain2:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 92(x6)
    bne x8, x5, qdrain2_sleep
    jal x0, qdrain2_done
qdrain2_sleep:
    wfi
    jal x0, qdrain2
qdrain2_done:
    addi x8, x0, 8
    sw x8, 0(x6)
    addi x8, x0, 49
    alu
    addi x16, x16, 8
    addi x18, x18, 36
    addi x1, x1, -1
    bne x1, x0, qchannel2
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x13, x0, 3
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack2
    jal x0, acked2
ack2:
    lw x8, 8(x12)
    bne x8, x13, ack2
acked2:
    lw x8, 168(x7)
    sw x8, 8(x6)
    lw x8, 184(x7)
    sw x8, 20(x6)
    lw x8, 192(x7)
    sw x8, 28(x6)
    lw x8, 200(x7)
    sw x8, 32(x6)
    lw x8, 212(x7)
    sw x8, 44(x6)
    lui x8, 0x80004
    addi x8, x8, 244
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    addi x8, x0, 49
    sw x8, 36(x6)
    addi x8, x0, 0
    sw x8, 48(x6)
    addi x31, x0, 1
    lw x1, 196(x7)
    lw x16, 176(x7)
    lw x17, 180(x7)
    lui x15, 0x80001
    addi x15, x15, 128
    addi x2, x0, 3
    lw x18, 172(x7)
    lui x30, 0x40000
    addi x30, x30, 1792
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 0
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
    sw x0, 28(x30)
qchannel3:
    sw x18, 12(x6)
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    addi x3, x0, 0
qrow3:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
qspace3:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, qsubmit3
    jal x0, qspace3
qsubmit3:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, qrow3
    lw x5, 96(x6)
qdrain3:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 92(x6)
    bne x8, x5, qdrain3_sleep
    jal x0, qdrain3_done
qdrain3_sleep:
    wfi
    jal x0, qdrain3
qdrain3_done:
    addi x8, x0, 8
    sw x8, 0(x6)
    addi x8, x0, 9
    alu
    addi x16, x16, 8
    addi x18, x18, 72
    addi x1, x1, -1
    bne x1, x0, qchannel3
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x13, x0, 4
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack3
    jal x0, acked3
ack3:
    lw x8, 8(x12)
    bne x8, x13, ack3
acked3:
    lw x8, 224(x7)
    sw x8, 8(x6)
    lw x8, 240(x7)
    sw x8, 20(x6)
    lw x8, 248(x7)
    sw x8, 28(x6)
    lw x8, 256(x7)
    sw x8, 32(x6)
    lw x8, 268(x7)
    sw x8, 44(x6)
    lui x8, 0x80004
    addi x8, x8, 244
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    addi x8, x0, 9
    sw x8, 36(x6)
    addi x8, x0, 0
    sw x8, 48(x6)
    addi x31, x0, 1
    lw x1, 252(x7)
    lw x16, 232(x7)
    lw x17, 236(x7)
    lui x15, 0x80001
    addi x15, x15, 224
    addi x2, x0, 3
    lw x18, 228(x7)
    lui x30, 0x40000
    addi x30, x30, 1792
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 0
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
    sw x0, 28(x30)
qchannel4:
    sw x18, 12(x6)
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    addi x3, x0, 0
qrow4:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
qspace4:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, qsubmit4
    jal x0, qspace4
qsubmit4:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, qrow4
    lw x5, 96(x6)
qdrain4:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 92(x6)
    bne x8, x5, qdrain4_sleep
    jal x0, qdrain4_done
qdrain4_sleep:
    wfi
    jal x0, qdrain4
qdrain4_done:
    addi x8, x0, 8
    sw x8, 0(x6)
    addi x8, x0, 9
    alu
    addi x16, x16, 8
    addi x18, x18, 72
    addi x1, x1, -1
    bne x1, x0, qchannel4
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x13, x0, 5
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack4
    jal x0, acked4
ack4:
    lw x8, 8(x12)
    bne x8, x13, ack4
acked4:
    lui x13, 0x40000
    addi x13, x13, 256
    lui x14, 0x40000
    addi x14, x14, 512
    addi x31, x0, 1
    lw x15, 280(x7)
    lw x16, 288(x7)
    lw x17, 292(x7)
    lw x18, 284(x7)
    lui x29, 0x80004
    addi x29, x29, 216
    addi x9, x15, 0
    lui x10, 0x80808
    addi x10, x10, 128
    addi x11, x0, 36
outer_fc_recenter:
    lw x8, 0(x9)
    alu
    sw x8, 0(x9)
    addi x9, x9, 4
    addi x11, x11, -1
    bne x11, x0, outer_fc_recenter
    addi x8, x0, 1
    sw x8, 20(x13)
    addi x8, x0, 144
    sw x8, 28(x13)
    addi x8, x0, 0
    sw x8, 52(x13)
    addi x8, x0, 144
    sw x8, 56(x13)
    addi x8, x0, 0
    sw x8, 60(x13)
    addi x8, x0, 1
    sw x8, 64(x13)
    addi x1, x0, 3
outer_fc_block:
    addi x3, x0, 4
    addi x11, x0, 1
    bne x1, x11, outer_fc_full
    addi x3, x0, 2
outer_fc_full:
    sw x3, 24(x13)
    sw x29, 16(x13)
    addi x9, x15, 0
    addi x10, x18, 0
    addi x4, x0, 2
outer_fc_tile:
    sw x9, 8(x13)
    sw x10, 12(x13)
    sw x4, 48(x13)
outer_fc_space:
    lw x8, 36(x13)
    andi x11, x8, 255
    shift
    bne x11, x8, outer_fc_submit
    jal x0, outer_fc_space
outer_fc_submit:
    sw x31, 0(x13)
    addi x18, x18, 576
    addi x29, x29, 16
    addi x1, x1, -1
    bne x1, x0, outer_fc_block
    lw x5, 44(x13)
outer_fc_raw_drain:
    addi x8, x0, 8
    sw x8, 0(x13)
    lw x8, 4(x13)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 40(x13)
    bne x8, x5, outer_fc_raw_drain_sleep
    jal x0, outer_fc_raw_drain_done
outer_fc_raw_drain_sleep:
    wfi
    jal x0, outer_fc_raw_drain
outer_fc_raw_drain_done:
    addi x8, x0, 8
    sw x8, 0(x13)
    addi x8, x0, 0
    sw x8, 56(x13)
    lui x29, 0x80004
    addi x29, x29, 216
    addi x8, x0, 1
    sw x8, 20(x13)
    sw x8, 24(x13)
    addi x8, x0, 0
    sw x8, 28(x13)
    addi x8, x0, 4
    sw x8, 48(x13)
    addi x1, x0, 10
    lui x30, 0x40000
    addi x30, x30, 1856
    addi x8, x0, 24
    sw x8, 12(x30)
    addi x8, x0, 75
    sw x8, 16(x30)
    addi x8, x0, 0
    sw x8, 20(x30)
    addi x8, x0, 255
    sw x8, 24(x30)
outer_fc_quant_channel:
    lw x8, 0(x16)
    sw x8, 4(x30)
    lw x8, 4(x16)
    sw x8, 8(x30)
    lw x8, 8(x16)
    sw x8, 28(x30)
    sw x17, 32(x30)
    addi x8, x0, 3
    sw x8, 0(x30)
    sw x29, 16(x13)
    sw x31, 0(x13)
    lw x5, 44(x13)
outer_fc_quant_drain:
    addi x8, x0, 8
    sw x8, 0(x13)
    lw x8, 4(x13)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 40(x13)
    bne x8, x5, outer_fc_quant_drain_sleep
    jal x0, outer_fc_quant_drain_done
outer_fc_quant_drain_sleep:
    wfi
    jal x0, outer_fc_quant_drain
outer_fc_quant_drain_done:
    addi x8, x0, 8
    sw x8, 0(x13)
    addi x8, x0, 0
    sw x8, 0(x30)
    addi x29, x29, 4
    addi x17, x17, 1
    addi x16, x16, 12
    addi x1, x1, -1
    bne x1, x0, outer_fc_quant_channel
    addi x13, x0, 6
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack5
    jal x0, acked5
ack5:
    lw x8, 8(x12)
    bne x8, x13, ack5
acked5:
    lui x7, 0x80001
    addi x7, x7, 1024
    lw x11, 0(x7)
    andi x8, x11, 255
    addi x9, x0, 0
    addi x10, x0, 1
    addi x16, x0, 10
argmax:
    shift
    andi x17, x10, 3
    bne x17, x0, loaded
    addi x7, x7, 4
    lw x11, 0(x7)
loaded:
    andi x18, x11, 255
    bge
    addi x8, x18, 0
    addi x9, x10, 0
skip:
    addi x10, x10, 1
    bne x10, x16, argmax
    sw x9, 0(x12)
    lui x6, 0x40000
    addi x6, x6, 0
    lui x5, 0x600d0
    addi x5, x5, 1
    sw x5, 4(x6)
    jal x0, halt
fail:
    lui x6, 0x40000
    addi x6, x6, 0
    lui x5, 0xbad00
    addi x5, x5, 1
    sw x5, 4(x6)
halt:
    jal x0, halt