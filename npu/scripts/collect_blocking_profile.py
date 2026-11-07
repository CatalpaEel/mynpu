"""Audit the two MNIST software paths and emit cycle partitions and wait events."""

import collections
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
area = json.loads((NPU / "reports/area25_area_validation.json").read_text())
variants = {}
for variant, expected in [("quant", 27432), ("default", 29173)]:
    folder = NPU / "build" / f"vcs-area18_final_{variant}-blocking-macro"
    r = json.loads((folder / "result.json").read_text())
    assert r["passed"] and not r["changed_during_run"]
    for name, sha in r["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (variant, name)
        rel = Path(name).relative_to(ROOT) if Path(name).is_relative_to(ROOT) else None
        if rel and str(rel).startswith("npu/rtl/"):
            assert area["source_sha256"][str(rel)] == sha
    compile_text = (folder / "compile-launcher.log").read_text()
    assert "Warning-[IPDW]" not in compile_text and "Warning-[PCWM-W]" not in compile_text
    text = (folder / "run.log").read_text()
    parsed = {}
    for prefix in [
        "STAGE_PROFILE",
        "CPU_BLOCK_PROFILE",
        "CPU_SOFTWARE_PROFILE",
        "BUS_BLOCK_PROFILE",
    ]:
        data = {}
        for line in text.splitlines():
            if line.startswith(prefix + " "):
                values = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
                sample = values.pop("sample")
                stage = values.pop("stage")
                assert (sample, stage) not in data
                data[sample, stage] = values
        assert len(data) == 70, (variant, prefix, len(data))
        for sample in range(10):
            stages = [data[sample, s] for s in range(7)]
            if prefix == "CPU_BLOCK_PROFILE":
                assert all(
                    d["cycles"] == sum(v for k, v in d.items() if k != "cycles") for d in stages
                )
                assert sum(d["cycles"] for d in stages) == expected
            if prefix == "CPU_SOFTWARE_PROFILE":
                assert sum(sum(d.values()) for d in stages) == expected
            if prefix == "STAGE_PROFILE":
                assert sum(d["cycles"] for d in stages) == expected
                for d in stages:
                    assert d["cnn_busy"] == sum(
                        d[k]
                        for k in [
                            "cnn_issue",
                            "cnn_weight",
                            "cnn_output",
                            "cnn_seed",
                            "cnn_input",
                            "cnn_other",
                        ]
                    )
                    assert d["matrix_busy"] == sum(
                        d[k]
                        for k in [
                            "matrix_fetch",
                            "matrix_words",
                            "matrix_clear",
                            "matrix_emit",
                            "matrix_creq",
                            "matrix_cwait",
                            "matrix_dreq",
                            "matrix_dwait",
                        ]
                    )
                    assert (
                        d["cycles"]
                        == d["no_engine"]
                        + d["cnn_busy"]
                        + d["vector_busy"]
                        + d["matrix_busy"]
                        - d["both_cnn_vector"]
                        - d["both_matrix_vector"]
                    )
        totals = []
        for sample in range(10):
            c = collections.Counter()
            for s in range(7):
                c.update(data[sample, s])
            totals.append(dict(c))
        keys = totals[0].keys()
        parsed[prefix] = dict(
            mean={k: sum(t[k] for t in totals) / 10 for k in keys},
            min={k: min(t[k] for t in totals) for k in keys},
            max={k: max(t[k] for t in totals) for k in keys},
            per_sample=totals,
            stages_mean=[
                {k: sum(data[n, s][k] for n in range(10)) / 10 for k in keys} for s in range(7)
            ],
        )
    variants[variant] = dict(
        cycles=expected,
        samples=10,
        result=str((folder / "result.json").relative_to(ROOT)),
        result_sha256=hashlib.sha256((folder / "result.json").read_bytes()).hexdigest(),
        run_log_sha256=hashlib.sha256((folder / "run.log").read_bytes()).hexdigest(),
        profile=parsed,
        pc_ranges=json.loads((folder / "block_pc_ranges.json").read_text()),
    )
report = dict(
    passed=True,
    area_reference="npu/reports/area25_area_validation.json",
    rtl_matches_18ns_gated_design=True,
    scope="RTL simulation with real SRAM macros, cycle counts at sys_clk; no wall-time simulation speed or silicon power claim",
    variants=variants,
    notes=[
        "CPU_BLOCK_PROFILE and CPU_SOFTWARE_PROFILE are separate exclusive partitions; do not add across views.",
        "BUS_BLOCK_PROFILE events overlap each other and engine activity; not additive inference time.",
        "PC poll ranges come from actual binary backward branches to named polling labels, not the text span up to the next label.",
        "other_awake includes instruction execution, branch/control bubbles and polling; it does not mean useful NPU computation.",
        "Matrix request wait uses master 5; the original legacy matrix_req_stall field used master 1 and is not used here.",
        "The legacy vector_input_wait field was never incremented; use new Vector A_REQ/A_WAIT and actual request-denial counters.",
        "The physical design uses clock gates; these observers measure system-clock cycles and CPU sleep, not all individual gated clock pulse counts.",
    ],
)
(NPU / "reports/area18_blocking_profile.json").write_text(json.dumps(report, indent=2) + "\n")
for v, d in variants.items():
    print(
        v,
        d["cycles"],
        "CPU",
        d["profile"]["CPU_BLOCK_PROFILE"]["mean"],
        "software",
        d["profile"]["CPU_SOFTWARE_PROFILE"]["mean"],
    )
