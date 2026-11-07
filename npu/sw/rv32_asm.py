#!/usr/bin/env python3
"""Dependency-free assembler for a small, real RV32I MMIO self-test."""

from pathlib import Path

code = []
labels = {}
listing = []


def emit(word, text):
    code.append(word & 0xFFFFFFFF)
    listing.append("    " + text)


def label(name):
    labels[name] = 0x80 + 4 * len(code)
    listing.append(name + ":")


def lui(rd, upper):
    emit(((upper & 0xFFFFF) << 12) | (rd << 7) | 0x37, f"lui x{rd}, 0x{upper & 0xFFFFF:x}")


def addi(rd, rs, imm):
    emit(((imm & 0xFFF) << 20) | (rs << 15) | (rd << 7) | 0x13, f"addi x{rd}, x{rs}, {imm}")


def li(rd, value):
    value &= 0xFFFFFFFF
    low = value & 0xFFF
    if low & 0x800:
        low -= 4096
    upper = ((value - low) >> 12) & 0xFFFFF
    if upper:
        lui(rd, upper)
        addi(rd, rd, low)
    else:
        addi(rd, 0, low)


def sw(rs, base, off):
    emit(
        ((off >> 5 & 0x7F) << 25)
        | (rs << 20)
        | (base << 15)
        | (2 << 12)
        | ((off & 31) << 7)
        | 0x23,
        f"sw x{rs}, {off}(x{base})",
    )


def lw(rd, base, off):
    emit(
        ((off & 0xFFF) << 20) | (base << 15) | (2 << 12) | (rd << 7) | 3,
        f"lw x{rd}, {off}(x{base})",
    )


def andi(rd, rs, imm):
    emit(
        ((imm & 0xFFF) << 20) | (rs << 15) | (7 << 12) | (rd << 7) | 0x13,
        f"andi x{rd}, x{rs}, {imm}",
    )


def branch(rs1, rs2, target):
    code.append(("bne", rs1, rs2, target))
    listing.append(f"    bne x{rs1}, x{rs2}, {target}")


def jump(target):
    code.append(("jal", target))
    listing.append(f"    jal x0, {target}")


def write_mmio(off, val):
    li(5, val)
    sw(5, 6, off)


def poll(off, name):
    li(9, 8192)
    label(name)
    lw(8, 6, off)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    andi(10, 8, 2)
    branch(10, 0, name + "_done")
    addi(9, 9, -1)
    branch(9, 0, name)
    jump("fail")
    label(name + "_done")


def check(off, values):
    for i, val in enumerate(values):
        lw(8, 7, off + 4 * i)
        li(11, val)
        branch(8, 11, "fail")


def reset():
    code.clear()
    labels.clear()
    listing.clear()


def bge(a, b, target):
    code.append(("bge", a, b, target))
    listing.append(f"    bge x{a}, x{b}, {target}")


def sub(rd, a, b):
    emit((0x20 << 25) | (b << 20) | (a << 15) | (rd << 7) | 0x33, f"sub x{rd}, x{a}, x{b}")


def call(target):
    code.append(("call", target))
    listing.append(f"    jal x30, {target}")


def ret():
    emit((30 << 15) | 0x67, "jalr x0, 0(x30)")


def resolve():
    for i, w in enumerate(code):
        if isinstance(w, int):
            continue
        pc = 0x80 + 4 * i
        if w[0] in ("bne", "bge"):
            _, a, b, t = w
            off = labels[t] - pc
            assert -4096 <= off < 4096, (w, off)
            f = 1 if w[0] == "bne" else 5
            code[i] = (
                ((off >> 12 & 1) << 31)
                | ((off >> 5 & 63) << 25)
                | (b << 20)
                | (a << 15)
                | (f << 12)
                | ((off >> 1 & 15) << 8)
                | ((off >> 11 & 1) << 7)
                | 0x63
            )
        else:
            off = labels[w[1]] - pc
            rd = 30 if w[0] == "call" else 0
            code[i] = (
                ((off >> 20 & 1) << 31)
                | ((off >> 1 & 1023) << 21)
                | ((off >> 11 & 1) << 20)
                | ((off >> 12 & 255) << 12)
                | (rd << 7)
                | 0x6F
            )
