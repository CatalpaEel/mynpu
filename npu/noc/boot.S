_start:
    lui x5, 0x200
    addi x5, x5, 0
    csrw mie,x5
    csrci mstatus,8
    lui x6, 0x40000
    addi x6, x6, 1792
    addi x5, x0, 273
    sw x5, 8(x6)
    lui x5, 0x80002
    addi x5, x5, -1536
    sw x5, 12(x6)
    addi x5, x0, 16
    sw x5, 16(x6)
    lui x5, 0x80001
    addi x5, x5, 1024
    sw x5, 20(x6)
    lui x5, 0x2
    addi x5, x5, 1808
    sw x5, 24(x6)
    addi x5, x0, 1
    sw x5, 0(x6)
wait:
    wfi
    lw x8, 4(x6)
    andi x10, x8, 4
    bne x10, x0, fail
    andi x10, x8, 2
    bne x10, x0, done
    jal x0, wait
done:
    lw x8, 28(x6)
    addi x11, x0, 16
    bne x8, x11, fail
    addi x5, x0, 2
    sw x5, 0(x6)
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