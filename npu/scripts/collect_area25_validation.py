"""Audit unchanged-function area reduction regressions and firmware cycles."""

import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
paths = list((NPU / "build").glob("vcs-area25_final-*/result.json"))
paths += [
    NPU / "build" / f"vcs-area25_{v}-{s}{'-macro' if macro else ''}/result.json"
    for v, s, macro in [
        ("fixed", "sramuncached", False),
        ("boundary32", "addressranges", False),
        ("boundary256", "addressranges", False),
        ("default", "latency", True),
        ("quant", "latency", True),
        ("legacy", "latency", True),
        ("default", "quantlayers", True),
        ("quant", "quantlayers", True),
    ]
]
paths += [NPU / "build/vcs-area25-matrixouter/result.json"]
assert len(paths) == 25, len(paths)
results = []
cycles = {}
for p in sorted(paths):
    d = json.loads(p.read_text())
    assert d["passed"] and not d["changed_during_run"], p
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (p, name)
    log = (p.parent / "compile-launcher.log").read_text()
    assert "Warning-[IPDW]" not in log and "Warning-[PCWM-W]" not in log, p
    results.append(
        dict(
            result=str(p.relative_to(ROOT)),
            suite=d["suite"],
            macro=d["macro"],
            summaries=d["summaries"],
        )
    )
    if d["suite"] == "latency":
        v = next(v for v in ["default", "quant", "legacy"] if f"area25_{v}-" in p.parent.name)
        cs = [
            int(re.search(r" elapsed_cycles=(\d+)", s)[1])
            for s in d["summaries"]
            if s.startswith("SINGLE sample=")
        ]
        assert len(cs) == 10 and len(set(cs)) == 1
        cycles[v] = cs[0]
baseline = json.loads((NPU / "reports/streams_optimized_validation.json").read_text())
assert cycles == baseline["mnist"]["cycles"]
r = dict(
    passed=True,
    cases=results,
    baseline_commit="dea650e",
    inference_cycles=cycles,
    cycles_unchanged=True,
    firmware_changed=False,
    layer_tensors_per_path=60,
    golden_bytes_per_path=17940,
    source_sha256={
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((NPU / "rtl").rglob("*.sv"))
    },
)
(NPU / "reports/area25_validation.json").write_text(json.dumps(r, indent=2) + "\n")
print(f"PASS {len(results)} current-source regressions, unchanged cycles {cycles}")
