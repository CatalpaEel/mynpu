_start:
    lui x5, 0x10
    addi x5, x5, 0
    csrw mie,x5
    csrci mstatus,8
    lui x6, 0x40000
    addi x6, x6, 1536
    lui x7, 0x80000
    addi x7, x7, 512
    lui x12, 0x80002
    addi x12, x12, -256
    addi x13, x0, 0
layer:
    lw x5, 0(x7)
    sw x5, 8(x6)
    lw x5, 4(x7)
    sw x5, 12(x6)
    lw x5, 8(x7)
    sw x5, 16(x6)
    lw x5, 12(x7)
    sw x5, 20(x6)
    lw x5, 16(x7)
    sw x5, 24(x6)
    lw x5, 20(x7)
    sw x5, 28(x6)
    lw x5, 24(x7)
    sw x5, 32(x6)
    lw x5, 28(x7)
    sw x5, 36(x6)
    lw x5, 32(x7)
    sw x5, 40(x6)
    lw x5, 36(x7)
    sw x5, 44(x6)
    lw x5, 40(x7)
    sw x5, 48(x6)
    lw x5, 44(x7)
    sw x5, 52(x6)
    lw x5, 48(x7)
    sw x5, 56(x6)
    lw x5, 52(x7)
    sw x5, 60(x6)
    addi x5, x0, 1
    sw x5, 0(x6)
    lui x9, 0xf4
    addi x9, x9, 576
poll:
    wfi
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    andi x10, x8, 2
    bne x10, x0, done
    addi x9, x9, -1
    bne x9, x0, poll
    jal x0, fail
done:
    addi x13, x13, 1
    sw x13, 4(x12)
    lw x5, 12(x12)
    bne x5, x0, ack
    jal x0, acked
ack:
    lw x8, 8(x12)
    bne x8, x13, ack
acked:
    addi x7, x7, 56
    addi x5, x0, 6
    bne x13, x5, layer
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