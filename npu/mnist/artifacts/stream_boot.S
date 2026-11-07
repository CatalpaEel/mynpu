_start:
    lui x5, 0x10
    addi x5, x5, 0
    csrw mie
    csrci mstatus,8
    lui x6, 0x40000
    addi x6, x6, 1536
    lw x8, -1456(x6)
    andi x8, x8, 511
    addi x5, x0, 32
    bne x8, x5, fail
    lw x8, -1448(x6)
    lui x5, 0x56504
    addi x5, x5, 1842
    bne x8, x5, fail
    lw x8, 84(x6)
    lui x5, 0x53444
    addi x5, x5, -1743
    bne x8, x5, fail
    lui x12, 0x80002
    addi x12, x12, -96
    addi x19, x0, 0
    addi x20, x0, 0
    addi x21, x0, 0
    lui x25, 0x80001
    addi x25, x25, 864
    addi x27, x0, 0
    addi x28, x0, 0
    lw x22, 24(x12)
    bne x22, x0, frame
    jal x0, fail
frame:
    shift
    alu
    addi x24, x19, 1
ready:
    lw x8, 0(x23)
    bne x8, x24, ready
    alu
    lui x7, 0x80001
    addi x7, x7, -1024
    addi x13, x0, 0
    lw x5, 0(x7)
    alu
    sw x5, 8(x6)
    lw x5, 4(x7)
    sw x5, 12(x6)
    lw x5, 16(x7)
    sw x5, 20(x6)
    lw x5, 24(x7)
    sw x5, 28(x6)
    lw x5, 32(x7)
    sw x5, 32(x6)
    lw x5, 44(x7)
    sw x5, 44(x6)
    lui x14, 0x40000
    addi x14, x14, 512
    addi x31, x0, 1
    lui x8, 0x80004
    addi x8, x8, 224
    sw x8, 24(x6)
    lui x8, 0x80006
    addi x8, x8, 0
    sw x8, 16(x6)
    sw x8, 8(x14)
    addi x8, x0, 0
    sw x8, 48(x6)
    addi x8, x0, 784
    sw x8, 36(x6)
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
    lui x8, 0x80004
    addi x8, x8, 0
    sw x8, 12(x6)
    lui x8, 0x5
    addi x8, x8, -1829
    sw x8, 64(x14)
    lui x8, 0x1
    addi x8, x8, -1861
    sw x8, 68(x14)
    addi x8, x0, 632
    sw x8, 72(x14)
    addi x8, x0, 532
    sw x8, 76(x14)
    addi x8, x0, 1520
    sw x8, 80(x14)
    addi x8, x0, 1047
    sw x8, 84(x14)
    lui x8, 0x60
    addi x8, x8, 406
    sw x8, 88(x14)
    addi x8, x0, 125
    sw x8, 92(x14)
    addi x8, x0, 1537
    sw x8, 96(x14)
    addi x8, x0, 1541
    sw x8, 100(x14)
    lui x8, 0x100
    addi x8, x8, -2044
    sw x8, 104(x14)
    addi x8, x0, 523
    sw x8, 52(x14)
    lw x1, 28(x7)
    addi x2, x0, 28
    lw x17, 12(x7)
    lui x15, 0x80001
    addi x15, x15, -688
    lw x16, 8(x7)
    addi x8, x0, 196
    sw x8, 16(x14)
    addi x8, x0, 160
    sw x8, 20(x14)
    lw x8, 48(x7)
    sw x8, 48(x14)
channel0:
    sw x17, 12(x14)
    sw x16, 24(x14)
vector_space0:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 36(x14)
    andi x10, x8, 255
    shift
    bne x10, x8, vector_submit0
    jal x0, vector_space0
vector_submit0:
    sw x31, 0(x14)
    addi x3, x0, 0
row0:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
space0:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, submit0
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    wfi
    jal x0, space0
submit0:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, row0
    addi x8, x0, 196
    alu
    addi x16, x16, 8
    addi x1, x1, -1
    bne x1, x0, channel0
    lw x5, 96(x6)
cnn_drain0:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 92(x6)
    bne x8, x5, cnn_sleep0
    jal x0, cnn_drained0
cnn_sleep0:
    wfi
    jal x0, cnn_drain0
cnn_drained0:
    lui x8, 0x20
    addi x8, x8, 0
    csrs mie,x8
    lw x5, 44(x14)
vector_drain0:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 40(x14)
    bne x8, x5, vector_sleep0
    jal x0, vector_drained0
vector_sleep0:
    wfi
    jal x0, vector_drain0
vector_drained0:
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x8, 0x20
    addi x8, x8, 0
    csrc mie,x8
    lw x27, 100(x6)
    lw x28, 104(x6)
    lw x5, 56(x7)
    sw x5, 8(x6)
    lw x5, 60(x7)
    sw x5, 12(x6)
    lw x5, 72(x7)
    sw x5, 20(x6)
    lw x5, 80(x7)
    sw x5, 28(x6)
    lw x5, 88(x7)
    sw x5, 32(x6)
    lw x5, 100(x7)
    sw x5, 44(x6)
    addi x8, x0, 196
    sw x8, 36(x6)
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
    lui x8, 0x80004
    addi x8, x8, 0
    sw x8, 12(x6)
    lw x1, 84(x7)
    addi x2, x0, 28
    lw x17, 68(x7)
    alu
    lui x15, 0x80001
    addi x15, x15, -464
    lw x16, 64(x7)
channel1:
    sw x17, 12(x14)
    sw x16, 24(x14)
vector_space1:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 36(x14)
    andi x10, x8, 255
    shift
    bne x10, x8, vector_submit1
    jal x0, vector_space1
vector_submit1:
    sw x31, 0(x14)
    addi x3, x0, 0
row1:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
space1:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, submit1
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    wfi
    jal x0, space1
submit1:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, row1
    addi x8, x0, 196
    alu
    addi x16, x16, 8
    addi x1, x1, -1
    bne x1, x0, channel1
    lw x5, 96(x6)
cnn_drain1:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 92(x6)
    bne x8, x5, cnn_sleep1
    jal x0, cnn_drained1
cnn_sleep1:
    wfi
    jal x0, cnn_drain1
cnn_drained1:
    lui x8, 0x20
    addi x8, x8, 0
    csrs mie,x8
    lw x5, 44(x14)
vector_drain1:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 40(x14)
    bne x8, x5, vector_sleep1
    jal x0, vector_drained1
vector_sleep1:
    wfi
    jal x0, vector_drain1
vector_drained1:
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x8, 0x20
    addi x8, x8, 0
    csrc mie,x8
    lw x27, 100(x6)
    lw x28, 104(x6)
    lw x5, 112(x7)
    alu
    sw x5, 8(x6)
    lw x5, 116(x7)
    sw x5, 12(x6)
    lw x5, 136(x7)
    sw x5, 28(x6)
    lw x5, 144(x7)
    sw x5, 32(x6)
    lw x1, 140(x7)
    addi x2, x0, 7
    lw x17, 124(x7)
    lui x15, 0x80001
    addi x15, x15, -16
    lw x16, 120(x7)
    addi x8, x0, 49
    sw x8, 16(x14)
channel2:
    sw x17, 12(x14)
    sw x16, 24(x14)
vector_space2:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 36(x14)
    andi x10, x8, 255
    shift
    bne x10, x8, vector_submit2
    jal x0, vector_space2
vector_submit2:
    sw x31, 0(x14)
    addi x3, x0, 0
row2:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
space2:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, submit2
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    wfi
    jal x0, space2
submit2:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, row2
    addi x8, x0, 49
    alu
    addi x16, x16, 8
    addi x1, x1, -1
    bne x1, x0, channel2
    lw x5, 96(x6)
cnn_drain2:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 92(x6)
    bne x8, x5, cnn_sleep2
    jal x0, cnn_drained2
cnn_sleep2:
    wfi
    jal x0, cnn_drain2
cnn_drained2:
    lui x8, 0x20
    addi x8, x8, 0
    csrs mie,x8
    lw x5, 44(x14)
vector_drain2:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 40(x14)
    bne x8, x5, vector_sleep2
    jal x0, vector_drained2
vector_sleep2:
    wfi
    jal x0, vector_drain2
vector_drained2:
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x8, 0x20
    addi x8, x8, 0
    csrc mie,x8
    lw x27, 100(x6)
    lw x28, 104(x6)
    lw x5, 168(x7)
    sw x5, 8(x6)
    lw x5, 172(x7)
    sw x5, 12(x6)
    lw x5, 184(x7)
    sw x5, 20(x6)
    lw x5, 192(x7)
    sw x5, 28(x6)
    addi x8, x0, 49
    sw x8, 36(x6)
    lw x1, 196(x7)
    addi x2, x0, 3
    lw x17, 180(x7)
    lui x15, 0x80001
    addi x15, x15, 208
    lw x16, 176(x7)
    addi x8, x0, 9
    sw x8, 16(x14)
channel3:
    sw x17, 12(x14)
    sw x16, 24(x14)
vector_space3:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 36(x14)
    andi x10, x8, 255
    shift
    bne x10, x8, vector_submit3
    jal x0, vector_space3
vector_submit3:
    sw x31, 0(x14)
    addi x3, x0, 0
row3:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
space3:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, submit3
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    wfi
    jal x0, space3
submit3:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, row3
    addi x8, x0, 9
    alu
    addi x16, x16, 8
    addi x1, x1, -1
    bne x1, x0, channel3
    lw x5, 96(x6)
cnn_drain3:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 92(x6)
    bne x8, x5, cnn_sleep3
    jal x0, cnn_drained3
cnn_sleep3:
    wfi
    jal x0, cnn_drain3
cnn_drained3:
    lui x8, 0x20
    addi x8, x8, 0
    csrs mie,x8
    lw x5, 44(x14)
vector_drain3:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 40(x14)
    bne x8, x5, vector_sleep3
    jal x0, vector_drained3
vector_sleep3:
    wfi
    jal x0, vector_drain3
vector_drained3:
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x8, 0x20
    addi x8, x8, 0
    csrc mie,x8
    lw x27, 100(x6)
    lw x28, 104(x6)
    lw x5, 224(x7)
    sw x5, 8(x6)
    lw x5, 228(x7)
    sw x5, 12(x6)
    lw x5, 240(x7)
    sw x5, 20(x6)
    lw x5, 256(x7)
    sw x5, 32(x6)
    addi x8, x0, 9
    sw x8, 36(x6)
    lw x1, 252(x7)
    addi x2, x0, 3
    lw x17, 236(x7)
    lui x15, 0x80001
    addi x15, x15, 304
    lw x16, 232(x7)
channel4:
    sw x17, 12(x14)
    sw x16, 24(x14)
vector_space4:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 36(x14)
    andi x10, x8, 255
    shift
    bne x10, x8, vector_submit4
    jal x0, vector_space4
vector_submit4:
    sw x31, 0(x14)
    addi x3, x0, 0
row4:
    lw x8, 0(x15)
    sw x8, 40(x6)
    addi x15, x15, 4
space4:
    lw x8, 88(x6)
    andi x10, x8, 255
    shift
    bne x10, x8, submit4
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    wfi
    jal x0, space4
submit4:
    sw x31, 0(x6)
    addi x3, x3, 1
    bne x3, x2, row4
    addi x8, x0, 9
    alu
    addi x16, x16, 8
    addi x1, x1, -1
    bne x1, x0, channel4
    lw x5, 96(x6)
cnn_drain4:
    addi x8, x0, 8
    sw x8, 0(x6)
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 92(x6)
    bne x8, x5, cnn_sleep4
    jal x0, cnn_drained4
cnn_sleep4:
    wfi
    jal x0, cnn_drain4
cnn_drained4:
    lui x8, 0x20
    addi x8, x8, 0
    csrs mie,x8
    lw x5, 44(x14)
vector_drain4:
    lw x8, 4(x14)
    andi x10, x8, 4
    bne x10, x0, fail
    lw x8, 40(x14)
    bne x8, x5, vector_sleep4
    jal x0, vector_drained4
vector_sleep4:
    wfi
    jal x0, vector_drain4
vector_drained4:
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x8, 0x20
    addi x8, x8, 0
    csrc mie,x8
    lw x27, 100(x6)
    lw x28, 104(x6)
    lui x13, 0x40000
    addi x13, x13, 256
    lui x14, 0x40000
    addi x14, x14, 512
    lw x15, 280(x7)
    lw x16, 288(x7)
    lw x17, 292(x7)
    alu
    lw x18, 284(x7)
    lui x29, 0x80004
    addi x29, x29, 216
    addi x9, x15, 0
    lui x10, 0x80808
    addi x10, x10, 128
    addi x11, x0, 36
fc_recenter:
    lw x8, 0(x9)
    alu
    sw x8, 0(x9)
    addi x9, x9, 4
    addi x11, x11, -1
    bne x11, x0, fc_recenter
    addi x8, x0, 1
    sw x8, 20(x13)
    sw x8, 24(x13)
    addi x8, x0, 16
    sw x8, 28(x13)
    addi x1, x0, 10
fc_channel:
    sw x29, 16(x13)
    addi x9, x15, 0
    addi x10, x18, 0
    addi x2, x0, 9
    addi x4, x0, 8
fc_tile:
    sw x9, 8(x13)
    sw x10, 12(x13)
    sw x4, 48(x13)
fc_matrix_space:
    lw x8, 4(x13)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 36(x13)
    andi x11, x8, 255
    shift
    bne x11, x8, fc_matrix_submit
    jal x0, fc_matrix_space
fc_matrix_submit:
    sw x31, 0(x13)
    addi x4, x0, 12
    addi x9, x9, 16
    addi x10, x10, 16
    addi x2, x2, -1
    bne x2, x0, fc_tile
    addi x18, x18, 144
    addi x29, x29, 4
    addi x1, x1, -1
    bne x1, x0, fc_channel
    lw x5, 44(x13)
fc_matrix_drain:
    lw x8, 4(x13)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 40(x13)
    bne x8, x5, fc_matrix_drain
    addi x8, x0, 2
    sw x8, 0(x13)
    lui x8, 0x5
    addi x8, x8, -1829
    sw x8, 64(x14)
    lui x8, 0x1
    addi x8, x8, -1861
    sw x8, 68(x14)
    addi x8, x0, 125
    sw x8, 72(x14)
    addi x8, x0, 1537
    sw x8, 76(x14)
    addi x8, x0, 632
    sw x8, 80(x14)
    addi x8, x0, 532
    sw x8, 84(x14)
    addi x8, x0, 1520
    sw x8, 88(x14)
    addi x8, x0, 1047
    sw x8, 92(x14)
    lui x8, 0x60
    addi x8, x8, 406
    sw x8, 96(x14)
    lui x8, 0x4c
    addi x8, x8, -2047
    sw x8, 100(x14)
    lui x8, 0x1
    addi x8, x8, -2043
    sw x8, 104(x14)
    lui x8, 0x100
    addi x8, x8, -2044
    sw x8, 108(x14)
    addi x8, x0, 524
    sw x8, 52(x14)
    addi x8, x0, 160
    sw x8, 20(x14)
    addi x8, x0, 1
    sw x8, 16(x14)
    lui x9, 0x80004
    addi x9, x9, 216
    addi x1, x0, 10
fc_post:
    lw x8, 8(x16)
    sw x8, 48(x14)
    sw x9, 8(x14)
    sw x17, 12(x14)
    sw x16, 24(x14)
fc_vector_space:
    lw x8, 4(x14)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 36(x14)
    andi x11, x8, 255
    shift
    bne x11, x8, fc_vector_submit
    jal x0, fc_vector_space
fc_vector_submit:
    sw x31, 0(x14)
    addi x9, x9, 4
    addi x17, x17, 1
    addi x16, x16, 12
    addi x1, x1, -1
    bne x1, x0, fc_post
    lw x5, 44(x14)
fc_vector_drain:
    lw x8, 4(x14)
    andi x11, x8, 4
    bne x11, x0, fail
    lw x8, 40(x14)
    bne x8, x5, fc_vector_drain
    addi x8, x0, 2
    sw x8, 0(x14)
    lui x30, 0x80002
    addi x30, x30, -880
    shift
    alu
    lw x8, 0(x26)
    sw x8, 0(x30)
    lw x8, 4(x26)
    sw x8, 4(x30)
    lw x8, 8(x26)
    shift
    shift
    sw x8, 8(x30)
    addi x7, x26, 0
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
    sw x9, 12(x30)
    sw x9, 16(x23)
    sw x27, 32(x12)
    sw x28, 36(x12)
    sw x24, 8(x23)
    addi x19, x19, 1
    bne x19, x22, more
    jal x0, success
more:
    xori
    addi x20, x0, 0
    bne x21, x0, slot1
    jal x0, frame
slot1:
    addi x20, x0, 1568
    jal x0, frame
success:
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