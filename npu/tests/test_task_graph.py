"""Software contract tests; numerical execution is checked by tb_workloads."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sw"))
from task_graph import Event, Graph, Plan, SPACE, WAIT, WRITE, MMIO


class LoweringTests(unittest.TestCase):
    def test_tail_k_and_scatter_dependencies(self):
        p = Plan()
        p.gemm(0x80000000, 0x80001400, 0x80003000, 1, 2, 257, 0x80003C00, lda=258, ldb=4, ldc=4)
        self.assertEqual(p.tickets, [2, 0, 0])
        flags = [b for op, a, b in p.commands if op == WRITE and a == MMIO + 0x130]
        self.assertEqual(flags, [0, 4])
        self.assertFalse(any(c[0] == WAIT for c in p.commands))
        self.assertIn((WRITE, MMIO + 0x158, 4), p.commands)

    def test_program_update_fences_active_and_pending(self):
        p = Plan()
        p.reduce(0x80000000, 0x80003000, 5, 0x80003C00)
        p.reduce(0x80000040, 0x80003004, 5, 0x80003C00, "max")
        # One program suffices: only the snapshotted scalar seed changes for
        # repeated max tasks, while sum -> max must replace the live opcode.
        configs = [
            i for i, (op, a, _) in enumerate(p.commands) if op == WRITE and a == MMIO + 0x234
        ]
        self.assertEqual(len(configs), 2)
        self.assertIn((WAIT, 1, 1), p.commands[: configs[1]])
        p.reduce(0x80000080, 0x80003008, 5, 0x80003C40, "max")
        self.assertEqual(sum(op == WRITE and a == MMIO + 0x234 for op, a, _ in p.commands), 2)

    def test_graph_roots_submit_before_join_waits(self):
        p, graph = Plan(), Graph()
        graph.add("a", lambda q: q.vector(0x80000000, 0, 0x80003000, 4))
        graph.add("b", lambda q: q.vector(0x80000040, 0, 0x80003040, 4))
        graph.add(
            "join", lambda q: q.vector(0x80003000, 0x80003040, 0x80003C00, 4, 1), after=("a", "b")
        )
        events = graph.lower(p)
        self.assertEqual(events["join"], Event(1, 3))
        self.assertFalse(any(c[0] == WAIT for c in p.commands))
        event_commands = [c[2] for c in p.commands if c[0] == WRITE and c[1] == MMIO + 0x29C]
        self.assertEqual(event_commands, [0x100, 0x200, 0x403])

    def test_missing_and_cyclic_graph_emit_nothing(self):
        for deps in (("missing",), ("self",)):
            p, graph = Plan(), Graph()
            graph.add("self", lambda q: q.vector(0x80000000, 0, 0x80003000, 4), after=deps)
            with self.assertRaises(ValueError):
                graph.lower(p)
            self.assertEqual(p.commands, [])

    def test_alias_and_invalid_layout_rejected(self):
        calls = [
            lambda p: p.transpose(0x80000000, 0x80000004, 3, 5),
            lambda p: p.strided(0x80000000, 0, 0x80000004, 5),
            lambda p: p.strided(0x80000000, 0, 0x80003000, 5, a_stride=2),
            lambda p: p.reduce(0x80000000, 0x80003001, 5, 0x80000004),
            lambda p: p.gemm(0x80000000, 0x80001400, 0x80000000, 2, 2, 3, 0x80003C00),
            lambda p: p.vector(0x80000000, 0x80001401, 0x80003000, 4, 1),
        ]
        for call in calls:
            p = Plan()
            with self.assertRaises(ValueError):
                call(p)
            self.assertEqual(p.commands, [])

    def test_batch_failure_is_transactional(self):
        p = Plan()
        with self.assertRaises(ValueError):
            p.batched_gemm(
                0x80000000,
                0x80001400,
                0x80003000,
                3,
                2,
                2,
                2,
                0x80003C00,
                a_stride=16,
                b_stride=0,
                d_stride=4,
            )
        self.assertEqual(p.commands, [])
        self.assertEqual(p.tickets, [0, 0, 0])

    def test_native_stride_zero_and_csr_reuse(self):
        p = Plan()
        p.strided(0x80000000, 0x80001400, 0x80003000, 13, b_stride=0, op=1)
        self.assertEqual(p.tickets, [0, 1, 0])
        self.assertIn((WRITE, MMIO + 0x290, 0), p.commands)
        p.strided(0x80000040, 0x80001400, 0x80003040, 13, b_stride=0, op=1)
        self.assertEqual(sum(c[0] == WRITE and c[1] == MMIO + 0x290 for c in p.commands), 1)
        p.strided(0x80000080, 0, 0x80003100, 4, d_stride=0)
        self.assertIn((WRITE, MMIO + 0x294, 0), p.commands)

    def test_reduce_no_scratch_and_final_only(self):
        p = Plan()
        p.reduce(0x80000000, 0x80003000, 5, None)
        self.assertEqual(p.tickets, [0, 1, 0])
        self.assertIn((WRITE, MMIO + 0x298, 1), p.commands)
        self.assertFalse(any(c[0] == WRITE and c[1] == 0x80003C00 for c in p.commands))

    def test_legacy_lowering_still_available(self):
        p = Plan(native=False)
        p.strided(0x80000000, 0x80001400, 0x80003000, 13, b_stride=0, op=1)
        self.assertEqual(p.tickets, [0, 13, 0])

    def test_raw_mmio_invalidates_cached_shadows_and_quant(self):
        p = Plan()
        p.csr(0x210, 4)
        p.write(MMIO + 0x210, 7)
        p.csr(0x210, 4)
        values = [c[2] for c in p.commands if c[0] == WRITE and c[1] == MMIO + 0x210]
        self.assertEqual(values, [4, 7, 4])
        p._raw_output(0)
        p.write(MMIO + 0x740, 1)
        p._raw_output(0)
        self.assertEqual(
            [c[2] for c in p.commands if c[0] == WRITE and c[1] == MMIO + 0x740], [0, 1, 0]
        )

    def test_preload_reduction_allows_queued_pipeline(self):
        p = Plan()
        p.prepare_reduction("sum")
        graph = Graph()
        graph.add("copy", lambda q: q.vector(0x80000000, 0, 0x80003000, 4))
        graph.add("sum", lambda q: q.reduce(0x80003000, 0x80003100, 4), after=("copy",))
        graph.lower(p)
        self.assertFalse(any(c[0] == WAIT for c in p.commands))
        self.assertEqual(
            [c[2] for c in p.commands if c[0] == WRITE and c[1] == MMIO + 0x29C], [0x100, 0x201]
        )

    def test_completion_wait_deduplication(self):
        p = Plan()
        p.wait(Event(0, 3))
        p.wait(Event(0, 2))
        p.wait(Event(0, 3))
        self.assertEqual(p.commands, [(WAIT, 0, 3)])


if __name__ == "__main__":
    unittest.main()
