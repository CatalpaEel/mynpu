"""Software lowering for raw integer kernels on the independent-unit NPU.

No model-specific hardware state is assumed. Plans start on quiescent queues;
completion tickets implement events, while shared program/quant state is fenced.
Addresses and strides are bytes; GEMM leading dimensions are elements.
"""

from dataclasses import dataclass
from typing import Callable

U32 = 0xFFFFFFFF
SRAM = 0x80000000
RF = 0x80004000
MMIO = 0x40000000
# Matrix, Vector, CNN: control, queue, submitted, completed.
UNITS = ((0x100, 0x124, 0x12C, 0x128), (0x200, 0x224, 0x22C, 0x228), (0x600, 0x658, 0x660, 0x65C))
WRITE, SPACE, WAIT, CHECK, MARK = range(5)


def span(base: int, size: int) -> None:
    if size <= 0 or not (SRAM <= base and base + size <= RF + 256):
        raise ValueError("tensor must fit SRAM or the configured 256-byte RF")
    if base < RF < base + size:
        raise ValueError("tensor may not straddle SRAM and RF")


def insn(op, rd, ra=0, rb=0, immediate=None):
    if not 0 <= op <= 31 or any(not 0 <= r < 4 for r in (rd, ra, rb)):
        raise ValueError("invalid instruction")
    if immediate is not None and not -(1 << 19) <= immediate < (1 << 19):
        raise ValueError("immediate20 out of range")
    return (
        op
        | (rd << 6)
        | (ra << 8)
        | (rb << 10)
        | (0 if immediate is None else 32 | ((immediate & 0xFFFFF) << 12))
    )


@dataclass(frozen=True)
class Event:
    unit: int
    ticket: int


class Plan:
    """An auditable MMIO command list; all arithmetic results wrap at 32 bits."""

    def __init__(self, native=True):
        self.native = native
        self._csr_cache = {}
        self._event_wait_mask = 0
        self._event_positions = {}
        self.commands = []
        self.tickets = [0, 0, 0]
        self.waited = [0, 0, 0]
        self.program = None
        self._raw = set()

    def write(self, address, value):
        # Raw MMIO is deliberately exposed. Invalidate our software assumptions
        # when a caller edits state through that path as well as through csr().
        if MMIO <= address < MMIO + 4096:
            offset = address - MMIO
            self._csr_cache.pop(offset, None)
            if offset == 0x234 or 0x240 <= offset <= 0x27C:
                self.program = None
            if offset in (0x700, 0x740):
                unit = 2 if offset == 0x700 else 0
                if value:
                    self._raw.discard(unit)
                else:
                    self._raw.add(unit)
        self.commands.append((WRITE, address, value & U32))

    def csr(self, offset, value):
        # Only software-owned shadow fields are cached. START, W1S/W1C, data
        # and externally observable side effects are never elided.
        shadow = offset in (
            0x108,
            0x10C,
            0x110,
            0x114,
            0x118,
            0x11C,
            0x130,
            0x134,
            0x138,
            0x13C,
            0x140,
            0x158,
            0x208,
            0x218,
            0x20C,
            0x210,
            0x214,
            0x230,
            0x28C,
            0x290,
            0x294,
            0x298,
            0x608,
            0x60C,
            0x610,
            0x614,
            0x618,
            0x61C,
            0x620,
            0x624,
            0x62C,
            0x630,
        )
        value &= U32
        if self.native and shadow and self._csr_cache.get(offset) == value:
            return
        self.write(MMIO + offset, value)
        if shadow:
            self._csr_cache[offset] = value

    def mark(self, name):
        self.commands.append((MARK, name, 0))

    def check(self, address, value):
        self.commands.append((CHECK, address, value & U32))

    def wait(self, event):
        if event is not None and event.ticket > self.waited[event.unit]:
            self.commands.append((WAIT, event.unit, event.ticket))
            self.waited[event.unit] = event.ticket

    def drain(self):
        for unit, ticket in enumerate(self.tickets):
            self.wait(Event(unit, ticket))

    def _raw_output(self, unit):
        if unit not in self._raw:
            self.wait(Event(unit, self.tickets[unit]))
            self.csr(0x740 if unit == 0 else 0x700, 0)
            self._raw.add(unit)

    def _submit(self, unit, fields):
        self.commands.append((SPACE, unit, 0))
        for offset, value in fields:
            self.csr(offset, value)
        if self.native:
            if unit == 1 and not any(offset == 0x298 for offset, _ in fields):
                self.csr(0x298, 0)
            event_offset = (0x15C, 0x29C, 0x674)[unit]
            self._event_positions[(unit, self.tickets[unit] + 1)] = len(self.commands)
            self.csr(event_offset, self._event_wait_mask)
        self.csr(UNITS[unit][0], 1)
        self.tickets[unit] += 1
        return Event(unit, self.tickets[unit])

    def vector(self, a, b, d, count, op=2, scalar=0):
        if not 1 <= count <= 4096 or op & ~0xDF:
            raise ValueError("invalid direct vector operation or length")
        if op & 31 not in (*range(16), 18, 19, 20, 24, 26):
            raise ValueError("unsupported direct vector opcode")
        words = (count + 3) // 4 if op & 64 else count
        for address in (a, d):
            span(address, words * 4)
            if address % 4:
                raise ValueError("unaligned vector address")
        if a != d and max(a, d) < min(a, d) + words * 4:
            raise ValueError("partial vector alias")
        if not op & 128 and op & 31 not in (0, 2, 13, 14, 15):
            span(b, words * 4)
            if b % 4 or (b != d and max(b, d) < min(b, d) + words * 4):
                raise ValueError("invalid vector B")
        return self._submit(
            1, [(0x208, a), (0x218, b), (0x20C, d), (0x210, count), (0x214, op), (0x230, scalar)]
        )

    def strided(self, a, b, d, count, a_stride=4, b_stride=4, d_stride=4, op=2, scalar=0):
        """Signed byte steps per 32-bit group; zero A/B broadcasts memory.

        Native mode emits one task and permits D=0 (last store wins). SIMD
        counts bytes, steps once per group. Legacy mode expands irregular views.
        Nontrivial overlapping views remain a software error.
        """
        if self.native:
            if (
                not 1 <= count <= 4096
                or op & ~0xDF
                or op & 31 not in (*range(16), 18, 19, 20, 24, 26)
            ):
                raise ValueError("invalid strided vector")
            steps = (a_stride, b_stride, d_stride)
            if any(step % 4 or not -32768 <= step <= 32767 for step in steps):
                raise ValueError("stride must be a signed16 word-aligned byte offset")
            iterations = (count + 3) // 4 if op & 64 else count
            binary = not op & 128 and op & 31 not in (0, 2, 13, 14, 15)

            def region(base, step):
                low, high = sorted((base, base + (iterations - 1) * step))
                span(low, high - low + 4)
                if base % 4:
                    raise ValueError("unaligned vector")
                return low, high + 4

            target = region(d, d_stride)
            for base, step in ((a, a_stride), *([(b, b_stride)] if binary else [])):
                low, high = region(base, step)
                if max(low, target[0]) < min(high, target[1]) and (base, step) != (d, d_stride):
                    raise ValueError("unsafe strided alias")
            return self._submit(
                1,
                [
                    (0x208, a),
                    (0x218, b),
                    (0x20C, d),
                    (0x210, count),
                    (0x214, op),
                    (0x230, scalar),
                    (0x28C, a_stride),
                    (0x290, b_stride),
                    (0x294, d_stride),
                    (0x298, 4),
                ],
            )
        if count < 1 or op & 64 or any(s % 4 for s in (a_stride, b_stride, d_stride)):
            raise ValueError("strided operation requires word elements")
        if count > 1 and d_stride == 0:
            raise ValueError("repeated destination")
        binary = not op & 128 and op & 31 not in (0, 2, 13, 14, 15)

        def extent(base, stride):
            low, high = sorted((base, base + (count - 1) * stride))
            span(low, high - low + 4)
            if base % 4:
                raise ValueError("unaligned strided view")
            return low, high + 4

        out = extent(d, d_stride)
        for base, stride in ((a, a_stride), *([(b, b_stride)] if binary else [])):
            low, high = extent(base, stride)
            if max(low, out[0]) < min(high, out[1]) and (base, stride) != (d, d_stride):
                raise ValueError("unsafe strided alias; use separate storage")
        if a_stride == d_stride == 4 and (not binary or b_stride == 4):
            event = None
            for off in range(0, count, 4096):
                event = self.vector(
                    a + off * 4,
                    b + off * 4 if binary else b,
                    d + off * 4,
                    min(4096, count - off),
                    op,
                    scalar,
                )
            return event
        event = None
        for i in range(count):
            event = self.vector(
                a + i * a_stride, b + i * b_stride if binary else b, d + i * d_stride, 1, op, scalar
            )
        return event

    def _program(self, words, loop):
        key = (tuple(words), loop)
        if self.program != key:
            # Program RAM is live, unlike the task's pointer/opcode snapshot.
            self.wait(Event(1, self.tickets[1]))
            for i, word in enumerate(words):
                self.csr(0x240 + 4 * i, word)
            self.csr(0x234, len(words) | (loop << 8))
            self.program = key

    def prepare_reduction(self, kind="sum"):
        """Preload the shared loop before enqueueing a dependent pipeline.

        Program words stay live: this method fences existing Vector jobs only
        when replacing the program. Tasks using the same loop reuse it.
        """
        if kind not in ("sum", "max", "min"):
            raise ValueError("invalid reduction")
        opcode = {"sum": 1, "max": 5, "min": 4}[kind]
        self._program([insn(29, 2), insn(opcode, 2, 2, 0), insn(2, 0, 2)], 1)
        return {"sum": 0, "max": 0x80000000, "min": 0x7FFFFFFF}[kind]

    def reduce(self, a, d, count, scratch=None, kind="sum"):
        """INT32 sum/max/min: native FINAL_ONLY writes one scalar, no scratch.

        Legacy lowering writes prefixes into 4*N bytes of caller workspace.
        Both forms use generic Vector instructions and persistent r2.
        """
        if kind not in ("sum", "max", "min") or not 1 <= count <= 4096:
            raise ValueError("invalid reduction")
        if self.native:
            span(a, count * 4)
            span(d, 4)
            if a % 4 or d % 4:
                raise ValueError("unaligned reduction")
            seed = self.prepare_reduction(kind)
            return self._submit(
                1,
                [
                    (0x208, a),
                    (0x218, a),
                    (0x20C, d),
                    (0x210, count),
                    (0x214, 32),
                    (0x230, seed),
                    (0x298, 1),
                ],
            )
        if scratch is None:
            raise ValueError("legacy reduction requires workspace")
        for base, size in ((a, count * 4), (scratch, count * 4), (d, 4)):
            span(base, size)
            if base % 4:
                raise ValueError("unaligned reduction")
        if max(a, scratch) < min(a, scratch) + count * 4:
            raise ValueError("reduction scratch aliases input")
        if max(d, scratch) < min(d + 4, scratch + count * 4):
            raise ValueError("reduction output aliases scratch")
        opcode = {"sum": 1, "max": 5, "min": 4}[kind]
        # A prologue initializes r2 from scalar; loop body preserves r2.
        words = [insn(29, 2), insn(opcode, 2, 2, 0), insn(2, 0, 2)]
        self._program(words, 1)
        seed = {"sum": 0, "max": 0x80000000, "min": 0x7FFFFFFF}[kind]
        self._submit(
            1,
            [(0x208, a), (0x218, a), (0x20C, scratch), (0x210, count), (0x214, 32), (0x230, seed)],
        )
        # FIFO order gives the copy a dependency without a CPU completion wait.
        return self.vector(scratch + (count - 1) * 4, 0, d, 1)

    def transpose(self, a, d, rows, cols):
        if rows < 1 or cols < 1:
            raise ValueError("invalid transpose shape")
        span(a, rows * cols * 4)
        span(d, rows * cols * 4)
        if max(a, d) < min(a, d) + rows * cols * 4:
            raise ValueError("transpose requires separate output")
        event = None
        for row in range(rows):
            event = self.strided(a + row * cols * 4, 0, d + row * 4, cols, d_stride=rows * 4)
        return event

    def gemm(
        self,
        a,
        b,
        d,
        m,
        n,
        k,
        scratch=None,
        *,
        lda=None,
        ldb=None,
        ldc=None,
        trans_a=False,
        trans_b=False,
        precision=0,
        element_bytes=4,
    ):
        """Tiled raw GEMM with independent precision and 1/2/4-byte storage.

        Native mode writes output ldc directly and needs no workspace. Legacy
        mode retains word storage and the tight-tile / Vector scatter path.
        """
        if self.native:
            return self._native_gemm(
                a,
                b,
                d,
                m,
                n,
                k,
                lda=lda,
                ldb=ldb,
                ldc=ldc,
                trans_a=trans_a,
                trans_b=trans_b,
                precision=precision,
                element_bytes=element_bytes,
            )
        if scratch is None:
            raise ValueError("legacy GEMM requires workspace")
        if element_bytes != 4:
            raise ValueError("legacy lowering requires word storage")
        if min(m, n, k) < 1 or precision not in (0, 1):
            raise ValueError("invalid GEMM")
        lda = lda if lda is not None else (m if trans_a else k)
        ldb = ldb if ldb is not None else (k if trans_b else n)
        ldc = n if ldc is None else ldc
        for base, rows, cols, stride in (
            (a, k if trans_a else m, m if trans_a else k, lda),
            (b, n if trans_b else k, k if trans_b else n, ldb),
            (d, m, n, ldc),
        ):
            if not cols <= stride <= 4096 or base % 4:
                raise ValueError("invalid leading dimension or address")
            span(base, ((rows - 1) * stride + cols) * 4)
        tile_words = min(m, 16) * min(n, 16)
        span(scratch, tile_words * 4)
        if scratch % 4:
            raise ValueError("unaligned scratch")
        regions = [
            (a, ((k if trans_a else m) - 1) * lda * 4 + (m if trans_a else k) * 4),
            (b, ((n if trans_b else k) - 1) * ldb * 4 + (k if trans_b else n) * 4),
            (d, ((m - 1) * ldc + n) * 4),
            (scratch, tile_words * 4),
        ]
        for i, (left, size) in enumerate(regions):
            for j, (right, length) in enumerate(regions[:i]):
                if i == 1 and j == 0:  # Read-only A/B may alias.
                    continue
                if max(left, right) < min(left + size, right + length):
                    raise ValueError("GEMM output/workspace alias")
        self._raw_output(0)
        event = None
        for row in range(0, m, 16):
            tm = min(16, m - row)
            for col in range(0, n, 16):
                tn = min(16, n - col)
                # Previous tile's Vector stores must finish before scratch reuse.
                self.wait(event)
                for inner in range(0, k, 256):
                    aa = a + ((inner * lda + row) if trans_a else (row * lda + inner)) * 4
                    bb = b + ((col * ldb + inner) if trans_b else (inner * ldb + col)) * 4
                    flags = int(trans_a) | (int(trans_b) << 1) | (4 if inner else 0)
                    matrix = self._submit(
                        0,
                        [
                            (0x108, aa),
                            (0x10C, bb),
                            (0x110, scratch),
                            (0x114, tm),
                            (0x118, tn),
                            (0x11C, min(256, k - inner)),
                            (0x130, flags),
                            (0x134, lda),
                            (0x138, ldb),
                            (0x13C, precision),
                            (0x140, 4),
                        ],
                    )
                self.wait(matrix)
                for r in range(tm):
                    event = self.vector(
                        scratch + r * tn * 4, 0, d + ((row + r) * ldc + col) * 4, tn
                    )
        return event

    def _native_gemm(
        self, a, b, d, m, n, k, *, lda, ldb, ldc, trans_a, trans_b, precision, element_bytes
    ):
        if (
            min(m, n, k) < 1
            or precision not in (0, 1)
            or element_bytes not in (1, 2, 4)
            or element_bytes < (2 if precision else 1)
        ):
            raise ValueError("invalid GEMM precision or storage")
        lda = lda if lda is not None else (m if trans_a else k)
        ldb = ldb if ldb is not None else (k if trans_b else n)
        ldc = ldc if ldc is not None else n
        regions = []
        for base, rows, cols, stride, size in (
            (a, k if trans_a else m, m if trans_a else k, lda, element_bytes),
            (b, n if trans_b else k, k if trans_b else n, ldb, element_bytes),
            (d, m, n, ldc, 4),
        ):
            if base % 4 or not cols <= stride <= 4096:
                raise ValueError("invalid GEMM layout")
            length = ((rows - 1) * stride + cols) * size
            span(base, length)
            regions.append((base, length))
        for source, size in regions[:2]:
            if max(source, d) < min(source + size, d + regions[2][1]):
                raise ValueError("GEMM output aliases input")
        self._raw_output(0)
        event = None
        for row in range(0, m, 16):
            for col in range(0, n, 16):
                for inner in range(0, k, 256):
                    aa = (
                        a
                        + ((inner * lda + row) if trans_a else (row * lda + inner)) * element_bytes
                    )
                    bb = (
                        b
                        + ((col * ldb + inner) if trans_b else (inner * ldb + col)) * element_bytes
                    )
                    event = self._submit(
                        0,
                        [
                            (0x108, aa),
                            (0x10C, bb),
                            (0x110, d + (row * ldc + col) * 4),
                            (0x114, min(16, m - row)),
                            (0x118, min(16, n - col)),
                            (0x11C, min(256, k - inner)),
                            (0x130, int(trans_a) | (int(trans_b) << 1) | (4 if inner else 0)),
                            (0x134, lda),
                            (0x138, ldb),
                            (0x13C, precision),
                            (0x140, element_bytes),
                            (0x158, ldc),
                        ],
                    )
        return event

    def conv3x3(
        self,
        src,
        kernel,
        dst,
        width,
        height,
        cin=1,
        cout=1,
        stride=1,
        input_zero=0,
        partial=RF + 192,
    ):
        """CHW U8 x OIHW I8, pad-one, raw INT32; postprocessing is separate.

        Shared CNN geometry is live until dispatch: fence its previous row
        before changing it. This is a reference lowering, not the hand-tuned
        MNIST scheduler. Output channels and rows are software loops.
        """
        if not (
            1 <= width <= 128
            and 1 <= height <= 128
            and 1 <= cin <= 256
            and cout >= 1
            and stride in (1, 2)
            and 0 <= input_zero <= 255
        ):
            raise ValueError("invalid convolution geometry")
        ow, oh = (width + stride - 1) // stride, (height + stride - 1) // stride
        regions = [
            (src, width * height * cin),
            (kernel, cout * cin * 9),
            (dst, cout * oh * ow * 4),
            (partial, min(16, ow) * 4),
        ]
        for base, size in regions:
            span(base, size)
        if src % 4 or dst % 4 or partial % 4:
            raise ValueError("unaligned convolution address")
        for i, (a, size) in enumerate(regions):
            for j, (b, length) in enumerate(regions[:i]):
                if i == 1 and j == 0:
                    continue
                if max(a, b) < min(a + size, b + length):
                    raise ValueError("convolution output/workspace alias")
        self._raw_output(2)
        event = None
        for oc in range(cout):
            for y in range(oh):
                self.wait(Event(2, self.tickets[2]))
                for offset, value in [
                    (0x608, src),
                    (0x60C, kernel + oc * cin * 9),
                    (0x610, dst + (oc * oh + y) * ow * 4),
                    (0x614, width),
                    (0x618, partial),
                    (0x61C, cin),
                    (0x620, stride),
                    (0x624, width * height),
                    (0x62C, input_zero),
                    (0x630, 0),
                ]:
                    self.csr(offset, value)
                rows = sum(1 << r for r in range(3) if 0 <= y * stride + r - 1 < height)
                for x in range(0, ow, 16):
                    count = min(16, ow - x)
                    task = (
                        (count - 1)
                        | (rows << 4)
                        | (int(x == 0) << 7)
                        | (int((x + count - 1) * stride + 1 >= width) << 8)
                        | (x << 9)
                        | (y << 16)
                        | (x << 23)
                    )
                    event = self._submit(2, [(0x628, task)])
        return event

    def batched_gemm(
        self, a, b, d, batches, m, n, k, scratch, *, a_stride, b_stride, d_stride, **layout
    ):
        """Explicit byte strides. Zero A/B batch stride broadcasts one tensor.

        Layout and scratch validation use the same per-batch GEMM lowering;
        inter-batch aliasing is conservatively rejected before any submission.
        """
        if batches < 1 or any(s < 0 or s % 4 for s in (a_stride, b_stride, d_stride)):
            raise ValueError("invalid batch stride")
        if batches > 1 and not d_stride:
            raise ValueError("batched output cannot broadcast")
        # Compile transactionally so a bad later batch never leaves a partial plan.
        import copy

        trial = copy.deepcopy(self)
        event = None
        for batch in range(batches):
            event = trial.gemm(
                a + batch * a_stride,
                b + batch * b_stride,
                d + batch * d_stride,
                m,
                n,
                k,
                scratch,
                **layout,
            )
        # All batch reads must survive all earlier output writes.
        ta, tb = layout.get("trans_a", False), layout.get("trans_b", False)
        lda = layout.get("lda") or (m if ta else k)
        ldb = layout.get("ldb") or (k if tb else n)
        ldc = layout.get("ldc") or n
        size = layout.get("element_bytes", 4) if self.native else 4
        asize = (((k if ta else m) - 1) * lda + (m if ta else k)) * size
        bsize = (((n if tb else k) - 1) * ldb + (k if tb else n)) * size
        dsize = ((m - 1) * ldc + n) * 4
        if batches > 1 and d_stride < dsize:
            raise ValueError("overlapping batch outputs")
        workspace = min(m, 16) * min(n, 16) * 4
        for i in range(batches):
            output = d + i * d_stride
            for j in range(batches):
                for source, size in ((a + j * a_stride, asize), (b + j * b_stride, bsize)):
                    if max(output, source) < min(output + dsize, source + size):
                        raise ValueError("batch output aliases another batch input")
                    if not self.native and max(scratch, source) < min(
                        scratch + workspace, source + size
                    ):
                        raise ValueError("batch workspace aliases input")
                if not self.native and max(scratch, output) < min(
                    scratch + workspace, output + dsize
                ):
                    raise ValueError("batch workspace aliases output")
        self.__dict__.update(trial.__dict__)
        return event


class Graph:
    """Explicit dependency graph; no model FSM or implicit buffer allocation.

    Native graphs of at most eight nodes use sticky hardware task events. Larger
    graphs and legacy lowering use CPU completion fences. Callers specify every
    RAW/WAR/WAW edge and own buffer/configuration lifetimes.
    """

    def __init__(self):
        self.nodes = {}

    def add(self, name: str, lower: Callable, after=()):
        if name in self.nodes:
            raise ValueError("duplicate graph node")
        self.nodes[name] = (lower, tuple(after))

    def lower(self, plan):
        # Validate the entire graph before emitting any MMIO.
        pending, order, resolved = set(self.nodes), [], set()
        while pending:
            ready = [
                n
                for n in self.nodes
                if n in pending and all(d in resolved for d in self.nodes[n][1])
            ]
            if not ready:
                raise ValueError("cyclic graph or missing dependency")
            order.extend(ready)
            resolved.update(ready)
            pending.difference_update(ready)
        import copy

        trial = copy.deepcopy(plan)
        hardware = trial.native and len(order) <= 8
        bits = {name: 1 << i for i, name in enumerate(order)} if hardware else {}
        if hardware:
            trial.drain()
            trial.csr(0x090, sum(bits.values()))
        events = {}
        for name in order:
            lower, deps = self.nodes[name]
            if hardware:
                trial._event_wait_mask = sum(bits[dep] for dep in set(deps))
            else:
                for dep in deps:
                    trial.wait(events[dep])
            events[name] = lower(trial)
            if not isinstance(events[name], Event):
                raise ValueError("graph nodes must return their final completion event")
            if hardware:
                event = events[name]
                position = trial._event_positions[(event.unit, event.ticket)]
                op, address, wait_mask = trial.commands[position]
                trial.commands[position] = (op, address, wait_mask | (bits[name] << 8))
                trial._event_wait_mask = 0
        plan.__dict__.update(trial.__dict__)
        return events
