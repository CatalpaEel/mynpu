"""Generate independent golden values and executable MMIO kernel workloads."""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sw"))
from task_graph import Graph, Plan, MARK


def build(native=True):
    p = Plan(native=native)
    cases = []
    a, b, d, scratch = 0x80000000, 0x80001400, 0x80003000, 0x80003C00

    def words(address, values):
        for i, value in enumerate(values):
            p.write(address + 4 * i, value)

    def case(name):
        p.drain()
        p.mark(name)
        cases.append(name)

    def check(address, values):
        p.drain()
        for i, value in enumerate(values):
            p.check(address + 4 * i, value)

    # Tail tiles, transposed storage, padded input/output strides, signed INT16.
    for m, n, k, ta, tb, precision in (
        (19, 5, 7, False, False, 0),
        (3, 17, 5, True, True, 1),
        (1, 2, 257, False, False, 0),
    ):
        case(f"gemm-{m}x{n}x{k}-ta{int(ta)}-tb{int(tb)}-i{16 if precision else 8}")
        aa = [
            [((r * 17 + c * 7) % 23 - 11) * (211 if precision else 1) for c in range(k)]
            for r in range(m)
        ]
        bb = [
            [((r * 11 + c * 3) % 19 - 9) * (109 if precision else 1) for c in range(n)]
            for r in range(k)
        ]
        ar, ac = (k, m) if ta else (m, k)
        br, bc = (n, k) if tb else (k, n)
        lda, ldb, ldc = ac + 1, bc + 2, n + 2
        av, bv = [0x55555555] * (ar * lda), [0x77777777] * (br * ldb)
        for r in range(ar):
            for c in range(ac):
                av[r * lda + c] = aa[c][r] if ta else aa[r][c]
        for r in range(br):
            for c in range(bc):
                bv[r * ldb + c] = bb[c][r] if tb else bb[r][c]
        words(a, av)
        words(b, bv)
        words(d, [0xA5A5A5A5] * (m * ldc))
        p.gemm(
            a,
            b,
            d,
            m,
            n,
            k,
            scratch,
            lda=lda,
            ldb=ldb,
            ldc=ldc,
            trans_a=ta,
            trans_b=tb,
            precision=precision,
        )
        p.drain()
        for r in range(m):
            for c in range(n):
                p.check(d + (r * ldc + c) * 4, sum(aa[r][j] * bb[j][c] for j in range(k)))
            for c in range(n, ldc):
                p.check(d + (r * ldc + c) * 4, 0xA5A5A5A5)

    case("int16-gemm-wraparound")
    limits = [-32768, 32767, -32768, 32767]
    words(a, limits)
    words(b, limits)
    p.gemm(a, b, d, 1, 1, 4, scratch, precision=1)
    check(d, [sum(x * x for x in limits)])

    case("outer-product-4x4")
    left, right = [-3, 5, 7, -9], [2, -4, 6, 8]
    words(a, left)
    words(b, right)
    p.gemm(a, b, d, 4, 4, 1, scratch)
    check(d, [x * y for x in left for y in right])

    case("broadcast-residual-reverse-stride")
    values = [i * 9 - 60 for i in range(13)]
    words(a, values)
    words(b, [31])
    p.strided(a, b, d, 13, b_stride=0, op=1)
    check(d, [x + 31 for x in values])
    p.strided(d + 48, 0, scratch, 13, a_stride=-4)
    check(scratch, list(reversed([x + 31 for x in values])))

    for kind, values in (
        ("sum", [0x7FFFFFFF, 3, -8, -100, 17]),
        ("max", [-55, -102, -1, -87, -9]),
        ("min", [15, 18, 1, 999, 5]),
    ):
        case(f"reduce-{kind}-int32")
        words(a, values)
        p.reduce(a, d, len(values), scratch, kind)
        check(
            d, [sum(values) if kind == "sum" else (max(values) if kind == "max" else min(values))]
        )

    case("transpose-3x5")
    values = [i - 9 for i in range(15)]
    words(a, values)
    p.transpose(a, d, 3, 5)
    check(d, [values[r * 5 + c] for c in range(5) for r in range(3)])

    case("branch-join-ticket-events")
    words(a, [-9, -2, 0, 3, 6, 20, 99])
    graph = Graph()
    graph.add("plus", lambda q: q.vector(a, 0, d, 7, 1 | 128, 5))
    graph.add("times", lambda q: q.vector(a, 0, d + 64, 7, 24 | 128, 3))
    graph.add("join", lambda q: q.vector(d, d + 64, scratch, 7, 1), after=("plus", "times"))
    graph.lower(p)
    check(scratch, [4 * x + 5 for x in [-9, -2, 0, 3, 6, 20, 99]])

    # SIMD tail verifies byte enables, not a claim of INT32 double throughput.
    case("simd8-tail-residual")
    values = [0xFC03FE01, 0xF807FA05, 0xCCCC0A09]
    words(a, values)
    words(d, [0xBBBBBBBB] * 3)
    p.vector(a, 0, d, 10, 1 | 64 | 128, 2)
    check(d, [0xFE050003, 0xFA09FC07, 0xBBBB0C0B])

    # RF producer -> SRAM vector consumer, same API / no special bypass wire.
    case("rf-gemv-activation")
    words(0x80004000, [1, -2, 3, 4])
    words(0x80004040, [2, 3, -1, 2, 5, 1, -3, -2])
    matrix_event = p.gemm(0x80004000, 0x80004040, d, 1, 2, 4, 0x80004080)
    # Legacy lowering ends in the Vector queue (its output copy); native GEMM
    # ends in Matrix. Only the latter needs a cross-unit fence before ReLU.
    if matrix_event.unit != 1:
        p.wait(matrix_event)
    p.vector(d, 0, scratch, 2, 0)
    check(scratch, [7, 0])  # [7, -6] -> ReLU
    for stride in (1, 2):
        case(f"cnn3x3-s{stride}-two-channel-vector-post")
        w, h, ci, co, zero = 5, 4, 2, 2, 121
        inputs = [((i * 29 + 7) % 256) for i in range(w * h * ci)]
        kernels = [(i * 5 % 11) - 5 for i in range(co * ci * 9)]

        def packed(address, data):
            for start in range(0, len(data), 4):
                word = sum(
                    (v & 255) << (8 * lane) for lane, v in enumerate(data[start : start + 4])
                )
                p.write(address + start, word)

        packed(a, inputs)
        packed(b, kernels)
        event = p.conv3x3(a, b, d, w, h, ci, co, stride, zero)
        p.wait(event)
        ow, oh = (w + stride - 1) // stride, (h + stride - 1) // stride
        reference = []
        for oc in range(co):
            for oy in range(oh):
                for ox in range(ow):
                    value = 0
                    for ic in range(ci):
                        for ky in range(3):
                            for kx in range(3):
                                yy, xx = oy * stride + ky - 1, ox * stride + kx - 1
                                pixel = (
                                    inputs[(ic * h + yy) * w + xx]
                                    if 0 <= yy < h and 0 <= xx < w
                                    else zero
                                )
                                value += (pixel - zero) * kernels[(oc * ci + ic) * 9 + ky * 3 + kx]
                    reference.append(value)
        check(d, reference)
        p.vector(d, 0, a + 0x800, len(reference), 0)
        check(a + 0x800, [max(0, v) for v in reference])

    case("batched-gemm-broadcast-weights")
    words(a, [1, -2, 3, 4, 5, -6, 7, 8, 9, -10, 11, 12])
    words(b, [2, -1, 3, 4, -2, 5])
    p.batched_gemm(a, b, d, 3, 2, 2, 2, scratch, a_stride=16, b_stride=0, d_stride=16)
    expected = []
    inputs = [1, -2, 3, 4, 5, -6, 7, 8, 9, -10, 11, 12]
    for off in range(0, 12, 4):
        for row in range(2):
            x, y = inputs[off + row * 2 : off + row * 2 + 2]
            expected += [2 * x + 3 * y, -x + 4 * y]
    check(d, expected)
    case("attention-qkt-row-max-subgraph")
    q = [[2, -1, 3, 4], [-2, 5, 1, -3]]
    keys = [[1, 2, -1, 3], [2, -3, 4, 1], [-1, 1, 2, -2]]
    words(a, [v for row in q for v in row])
    words(b, [v for row in keys for v in row])
    p.gemm(a, b, d, 2, 3, 4, scratch, trans_b=True)
    p.drain()
    scores = [[sum(x * y for x, y in zip(row, key)) for key in keys] for row in q]
    check(d, [v for row in scores for v in row])
    for row in range(2):
        p.reduce(d + row * 12, a + 0x800 + row * 4, 3, scratch, "max")
    check(a + 0x800, [max(row) for row in scores])

    case("maxpool2x2-software-gather-reduce")
    image = [i * 3 - 18 for i in range(16)]
    words(a, image)
    pooled = []
    for y in range(0, 4, 2):
        for x in range(0, 4, 2):
            p.strided(a + (y * 4 + x) * 4, 0, a + 0x800, 2)
            p.strided(a + ((y + 1) * 4 + x) * 4, 0, a + 0x808, 2)
            p.reduce(a + 0x800, d + len(pooled) * 4, 4, scratch, "max")
            pooled.append(max(image[(y + r) * 4 + x + c] for r in range(2) for c in range(2)))
    check(d, pooled)

    case("cnn-vector-independent-overlap-join")
    # Long CNN task gives the independent Vector branch time to run. Both
    # roots are queued before the join's completion fences.
    packed_input = [3] * (16 * 1 * 8)
    packed_weights = [1] * (9 * 8)
    for off in range(0, len(packed_input), 4):
        p.write(a + off, 0x03030303)
    for off in range(0, len(packed_weights), 4):
        p.write(b + off, 0x01010101)
    words(a + 0x800, list(range(16)))
    graph = Graph()
    graph.add("conv", lambda z: z.conv3x3(a, b, d, 16, 1, 8, partial=0x800040C0))
    graph.add("vector", lambda z: z.vector(a + 0x800, 0, d + 128, 16, 24 | 128, 2))
    graph.add("join", lambda z: z.vector(d, d + 128, scratch, 16, 1), after=("conv", "vector"))
    graph.lower(p)
    check(scratch, [48 + 2 * i if i in (0, 15) else 72 + 2 * i for i in range(16)])
    if native:
        for precision, element_bytes, ta, tb in ((0, 1, False, True), (1, 2, True, False)):
            case(f"packed-gemm-i{8 if precision == 0 else 16}-tails")
            m, n, k = 19, 17, 7
            ar, ac = (k, m) if ta else (m, k)
            br, bc = (n, k) if tb else (k, n)
            lda, ldb, ldc = ac + 2, bc + 2, n + 3
            left = [
                [((r * 7 + c * 3) % 17 - 8) * (151 if precision else 1) for c in range(k)]
                for r in range(m)
            ]
            right = [
                [((r * 3 + c * 5) % 13 - 6) * (107 if precision else 1) for c in range(n)]
                for r in range(k)
            ]
            av, bv = bytearray(ar * lda * element_bytes), bytearray(br * ldb * element_bytes)
            for r in range(ar):
                for c in range(ac):
                    value = left[c][r] if ta else left[r][c]
                    offset = (r * lda + c) * element_bytes
                    av[offset : offset + element_bytes] = value.to_bytes(
                        element_bytes, "little", signed=True
                    )
            for r in range(br):
                for c in range(bc):
                    value = right[c][r] if tb else right[r][c]
                    offset = (r * ldb + c) * element_bytes
                    bv[offset : offset + element_bytes] = value.to_bytes(
                        element_bytes, "little", signed=True
                    )
            for address, data in ((a, av), (b, bv)):
                for off in range(0, len(data), 4):
                    p.write(address + off, int.from_bytes(data[off : off + 4], "little"))
            words(d, [0xA5A5A5A5] * (m * ldc))
            p.gemm(
                a,
                b,
                d,
                m,
                n,
                k,
                scratch,
                lda=lda,
                ldb=ldb,
                ldc=ldc,
                trans_a=ta,
                trans_b=tb,
                precision=precision,
                element_bytes=element_bytes,
            )
            p.drain()
            for r in range(m):
                for c in range(n):
                    p.check(d + (r * ldc + c) * 4, sum(left[r][j] * right[j][c] for j in range(k)))
                for c in range(n, ldc):
                    p.check(d + (r * ldc + c) * 4, 0xA5A5A5A5)
        case("native-zero-output-stride")
        words(a, [11, 22, 33, 44, 55])
        words(d, [0xCCCCCCCC, 0x12345678])
        p.strided(a, 0, d, 5, d_stride=0)
        check(d, [55, 0x12345678])
    if native:
        case("cnn-wide-row-eight-windows")
        for off in range(0, 128, 4):
            p.write(a + off, int.from_bytes(bytes(range(off, off + 4)), "little"))
        words(b, [0, 1, 0])
        p.write(d + 512, 0xDEADBEEF)
        p.conv3x3(a, b, d, 128, 1)
        check(d, list(range(128)) + [0xDEADBEEF])
    return p, cases


def cpu_variants(out):
    from plan_rv32 import compile_plan

    variants = {}
    a, b, d, e = 0x80002000, 0x80002200, 0x80003000, 0x80003C00
    p = Plan()
    values = [i * 9 - 60 for i in range(13)]
    for i, value in enumerate(values):
        p.write(a + i * 4, value)
    p.write(b, 31)
    graph = Graph()
    graph.add("broadcast", lambda q: q.strided(a, b, d, 13, b_stride=0, op=1))
    graph.add("reverse", lambda q: q.strided(d + 48, 0, e, 13, a_stride=-4), after=("broadcast",))
    graph.lower(p)
    p.drain()
    for i, value in enumerate(values):
        p.check(d + i * 4, value + 31)
    for i, value in enumerate(reversed(values)):
        p.check(e + i * 4, value + 31)
    p.transpose(a, d + 0x100, 3, 4)
    p.drain()
    for i, value in enumerate([values[r * 4 + c] for c in range(4) for r in range(3)]):
        p.check(d + 0x100 + i * 4, value)
    variants["layout"] = (p, 38)
    p = Plan()
    left = [[((r * 7 + c * 3) % 17 - 8) * 151 for c in range(7)] for r in range(3)]
    right = [[((r * 3 + c * 5) % 13 - 6) * 107 for c in range(5)] for r in range(7)]
    for address, rows in ((a, left), (b, right)):
        data = b"".join(value.to_bytes(2, "little", signed=True) for row in rows for value in row)
        for i in range(0, len(data), 4):
            p.write(address + i, int.from_bytes(data[i : i + 4], "little"))
    p.gemm(a, b, d, 3, 5, 7, precision=1, element_bytes=2)
    p.drain()
    for r in range(3):
        for c in range(5):
            p.check(d + (r * 5 + c) * 4, sum(left[r][k] * right[k][c] for k in range(7)))
    variants["packed"] = (p, 15)
    p = Plan()
    for address, data in ((a, bytes(range(1, 10))), (b, bytes([0, 0, 0, 0, 1, 0, 0, 0, 0]))):
        for i in range(0, len(data), 4):
            p.write(address + i, int.from_bytes(data[i : i + 4], "little"))
    graph = Graph()
    graph.add("cnn", lambda q: q.conv3x3(a, b, d, 3, 3))
    graph.add("relu", lambda q: q.vector(d, 0, e, 9, 0), after=("cnn",))
    graph.lower(p)
    p.drain()
    for i in range(9):
        p.check(e + i * 4, i + 1)
    variants["cnn"] = (p, 9)
    return {
        name: dict(words=compile_plan(plan, out / "cpu_variants" / name), checks=checks)
        for name, (plan, checks) in variants.items()
    }


def generate(out, native=True):
    out.mkdir(parents=True, exist_ok=True)
    plan, cases = build(native)
    lines, rows = [], []
    mark = 0
    for op, a, b in plan.commands:
        if op == MARK:
            a = mark
            mark += 1
        lines.append(f"{op:08x} {a:08x} {b:08x}\n")
        rows.append(f"  {{{op}u, 0x{a:08x}u, 0x{b:08x}u}},\n")
    (out / "workloads.hex").write_text("".join(lines))
    (out / "workloads_plan.h").write_text(
        '#include "npu_plan.h"\nstatic const struct npu_plan_command npu_workloads[] = {\n'
        + "".join(rows)
        + "};\n"
    )
    from plan_rv32 import compile_plan

    cpu = Plan(native=native)
    ca, cb, cd, cs = 0x80002000, 0x80002200, 0x80003000, 0x80003C00
    for i, value in enumerate([1, -2, 3, 4, -5, 6, 7, -8]):
        cpu.write(ca + 4 * i, value)
    for i, value in enumerate([2, -1, 3, 4, 5, -2, -3, 1, 2, 6, -4, 5]):
        cpu.write(cb + 4 * i, value)
    if native:
        cpu.prepare_reduction("sum")
        pipeline = Graph()
        pipeline.add("gemm", lambda q: q.gemm(ca, cb, cd, 2, 3, 4))
        pipeline.add("bias", lambda q: q.vector(cd, 0, cd, 6, 1 | 128, 9), after=("gemm",))
        pipeline.add("sum", lambda q: q.reduce(cd, cd + 64, 6), after=("bias",))
        pipeline.lower(cpu)
    else:
        cpu.wait(cpu.gemm(ca, cb, cd, 2, 3, 4, cs))
        cpu.vector(cd, 0, cd, 6, 1 | 128, 9)
        cpu.reduce(cd, cd + 64, 6, cs)
    cpu.drain()
    golden = []
    av = [[1, -2, 3, 4], [-5, 6, 7, -8]]
    bv = [[2, -1, 3], [4, 5, -2], [-3, 1, 2], [6, -4, 5]]
    for row in av:
        for col in range(3):
            golden.append(sum(row[j] * bv[j][col] for j in range(4)) + 9)
    for i, value in enumerate(golden):
        cpu.check(cd + i * 4, value)
    cpu.check(cd + 64, sum(golden))
    cpu_words = compile_plan(cpu, out)
    variants = cpu_variants(out) if native else {}
    (out / "workload_cpu_plan.h").write_text(
        '#include "npu_plan.h"\nstatic const struct npu_plan_command npu_cpu_workload[] = {\n'
        + "".join(f"  {{{op}u, 0x{a:08x}u, 0x{b:08x}u}},\n" for op, a, b in cpu.commands)
        + "};\n"
    )
    (out / "workloads_manifest.json").write_text(
        json.dumps(
            {
                "cpu_words": cpu_words,
                "cpu_variants": variants,
                "cpu_checks": len(golden) + 1,
                "cases": cases,
                "commands": len(lines),
                "submitted": plan.tickets,
                "note": "Host-driven actual MMIO kernels; not CPU inference or full models.",
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--legacy", action="store_true")
    args = parser.parse_args()
    generate(args.out, not args.legacy)
