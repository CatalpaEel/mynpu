"""Lower a small reset-started Plan to actual RV32I software (no C toolchain).

Uses the existing assembler. This backend requires zero completion counters;
C npu_plan_execute also supports nonzero quiescent counters and wraparound.
"""

from pathlib import Path
import rv32_asm as asm
from task_graph import WRITE, SPACE, WAIT, CHECK, MARK, MMIO, UNITS


def compile_plan(plan, out: Path, timeout=100000):
    if not 1 <= timeout < 0x80000000:
        raise ValueError("invalid timeout")
    asm.reset()
    asm.label("_start")

    def fail_if_not_equal(left, right, label):
        asm.branch(left, right, label + "_bad")
        asm.jump(label + "_ok")
        asm.label(label + "_bad")
        asm.jump("fail")
        asm.label(label + "_ok")

    def shift(rd, rs, amount, right):
        asm.emit(
            (amount << 20) | (rs << 15) | ((5 if right else 1) << 12) | (rd << 7) | 0x13,
            f"{'srli' if right else 'slli'} x{rd}, x{rs}, {amount}",
        )

    # Assert reset-started, quiescent unit state rather than waiting on stale
    # tickets. The boot ROM has not submitted any accelerator work.
    for unit, (control, queue, submitted, completed) in enumerate(UNITS):
        for j, offset in enumerate((submitted, completed)):
            asm.li(5, MMIO + offset)
            asm.lw(8, 5, 0)
            fail_if_not_equal(8, 0, f"initial_{unit}_{j}")
    for i, (op, a, b) in enumerate(plan.commands):
        if op == WRITE:
            asm.li(5, a)
            asm.li(7, b)
            asm.sw(7, 5, 0)
            asm.emit(0x0FF0000F, "fence iorw, iorw")
        elif op == CHECK:
            asm.li(5, a)
            asm.lw(8, 5, 0)
            asm.li(11, b)
            fail_if_not_equal(8, 11, f"check_{i}")
        elif op in (SPACE, WAIT):
            control, queue, _, completed = UNITS[a]
            asm.li(12, timeout)
            asm.label(f"wait_{i}")
            asm.li(5, MMIO + control + 4)
            asm.lw(8, 5, 0)
            asm.andi(10, 8, 4)
            fail_if_not_equal(10, 0, f"fault_{i}")
            asm.li(5, MMIO + (queue if op == SPACE else completed))
            asm.lw(8, 5, 0)
            if op == SPACE:
                shift(10, 8, 16, False)
                shift(10, 10, 16, True)
                shift(11, 8, 16, True)
                asm.bge(10, 11, f"retry_{i}")
                asm.jump(f"done_{i}")
            else:
                asm.li(11, b)
                asm.sub(10, 8, 11)
                asm.bge(10, 0, f"done_{i}")
            asm.label(f"retry_{i}")
            asm.addi(12, 12, -1)
            asm.branch(12, 0, f"wait_{i}")
            asm.jump("fail")
            asm.label(f"done_{i}")
            asm.emit(0x0FF0000F, "fence iorw, iorw")
        elif op != MARK:
            raise ValueError("invalid plan opcode")
    asm.li(5, MMIO + 4)
    asm.li(7, 0x600D0001)
    asm.sw(7, 5, 0)
    asm.jump("halt")
    asm.label("fail")
    asm.li(5, MMIO + 4)
    asm.li(7, 0xBAD00001)
    asm.sw(7, 5, 0)
    asm.label("halt")
    asm.jump("halt")
    end = 0x80000080 + 4 * len(asm.code)
    if end > 0x80002000:
        raise ValueError("unrolled program exceeds reserved 8KB code region")
    for op, address, _ in plan.commands:
        if op in (WRITE, CHECK) and 0x80000000 <= address < end:
            raise ValueError("program overlaps workload data")
    asm.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "workload_cpu.hex").write_text("".join(f"{w:08x}\n" for w in [0] * 32 + asm.code))
    (out / "workload_cpu.S").write_text("\n".join(asm.listing) + "\n")
    return len(asm.code)
