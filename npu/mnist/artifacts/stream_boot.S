_start:
    lui x5, 0x10
    addi x5, x5, 0
    csrw mie
    csrci mstatus,8
    lui x6, 0x40000
    addi x6, x6, 1536
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
    lui x7, 0x80000
    addi x7, x7, 688
    addi x13, x0, 0
layer:
    addi x14, x7, 0
    addi x15, x6, 8
    addi x16, x0, 14
config:
    lw x5, 0(x14)
    bne x5, x25, keep
    alu
keep:
    sw x5, 0(x15)
    addi x14, x14, 4
    addi x15, x15, 4
    addi x16, x16, -1
    bne x16, x0, config
    addi x5, x0, 1
    sw x5, 0(x6)
wait:
    wfi
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    andi x10, x8, 2
    bne x10, x0, layer_done
    jal x0, wait
layer_done:
    lw x8, 64(x6)
    alu
    lw x8, 68(x6)
    alu
    addi x13, x13, 1
    addi x7, x7, 56
    addi x5, x0, 6
    bne x13, x5, layer
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
    lw x8, 0(x7)
    andi x8, x8, 255
    addi x9, x0, 0
    addi x10, x0, 1
argmax:
    shift
    shift
    alu
    lw x11, 0(x17)
    andi x18, x10, 3
    shift
    alu
    andi x11, x11, 255
    bge
    addi x8, x11, 0
    addi x9, x10, 0
skip:
    addi x10, x10, 1
    addi x11, x0, 10
    bne x10, x11, argmax
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