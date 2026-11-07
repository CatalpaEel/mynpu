"""Audit CNN/Matrix/Vector Stream simplification against the 4x4 baseline."""

import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
baseline = json.loads((NPU / "reports/matrix_outer4_validation.json").read_text())
assert baseline["passed"]
reuse = {"matrixouter", "purecompute", "queues", "regfile", "rfsink", "xbar"}
cases = [(c["suite"], c["macro"], c["variant"]) for c in baseline["cases"]] + [
    ("cnnstream", True, "default")
]
results = []
cycles = {}
for suite, macro, variant in cases:
    old = next(
        (c for c in baseline["cases"] if c["suite"] == suite and c["variant"] == variant), None
    )
    p = (
        ROOT / old["result"]
        if suite in reuse
        else NPU
        / "build"
        / f"vcs-streams_final_{variant}-{suite}{'-macro' if macro else ''}"
        / "result.json"
    )
    d = json.loads(p.read_text())
    assert d["passed"] and not d["changed_during_run"], p
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, ("stale", name, p)
    log = (p.parent / "compile-launcher.log").read_text()
    assert "Warning-[IPDW]" not in log and "Warning-[PCWM-W]" not in log, p
    results.append(
        dict(
            suite=suite,
            variant=variant,
            macro=macro,
            passed=True,
            reused_unchanged=suite in reuse,
            result=str(p.relative_to(ROOT)),
            summaries=d["summaries"],
        )
    )
    if suite == "latency":
        measured = [
            int(re.search(r" elapsed_cycles=(\d+)", s)[1])
            for s in d["summaries"]
            if s.startswith("SINGLE sample=")
        ]
        assert len(measured) == 10 and len(set(measured)) == 1
        cycles[variant] = measured[0]
assert cycles == baseline["mnist"]["cycles"], (cycles, baseline["mnist"]["cycles"])
for path in [
    "npu/rtl/matrix/npu_matrix_stream.sv",
    "npu/rtl/cnn/npu_stream_engine.sv",
    "npu/rtl/vector/npu_vector_stream.sv",
]:
    frozen = ROOT.parent / "eda-runs/20261107-stream-opt-before" / Path(path).name
    assert hashlib.sha256(frozen.read_bytes()).hexdigest() == baseline["source_sha256"][path]
files = list((NPU / "rtl").rglob("*.sv")) + [
    NPU / "rtl/files.f",
    NPU / "scripts/run_vcs.py",
    NPU / "tb/tb_cnn_stream.sv",
    NPU / "tb/tb_outer_gemm.sv",
]
report = dict(
    passed=True,
    baseline_commit="c0d288a",
    cases=results,
    changes=dict(
        matrix="incremental 15-bit validated operand pointers and 8-bit output indices; unchanged 3-slot coalescing/32B operand staging",
        cnn="shared 48-bit row funnel selection, exact left-border handling, bounded position/channel counters; unchanged prefetch/forwarding",
        vector="shared write/packing buffer; r1 reuses direct B pointer; LD32 reuses INT32 ADD; direct operand/tail selection simplified",
    ),
    mnist=dict(
        samples=10,
        cycles=cycles,
        baseline_cycles=baseline["mnist"]["cycles"],
        cycle_regression=False,
        layer_tensors_per_path=60,
        golden_bytes_per_path=17940,
        firmware_changed=False,
    ),
    ppa=dict(synthesis_measured=False, timing_measured=False, pnr_measured=False),
    source_sha256={
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)
    },
)
(NPU / "reports/streams_optimized_validation.json").write_text(
    json.dumps(report, indent=2, ensure_ascii=False) + "\n"
)
print(
    f"PASS {len(results)} verified suites (15 rerun,6 unchanged reused); unchanged inference cycles {cycles}"
)
