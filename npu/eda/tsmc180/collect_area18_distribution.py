"""Conservative instance-prefix attribution on the exact 18ns gated netlist."""

import argparse
import collections
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--hier-run", type=Path)
a = p.parse_args()
run = a.run.resolve()
reference = json.loads((ROOT / "npu/reports/area25_area_validation.json").read_text())
assert str(run) == reference["run"]
for name, sha in reference["run_file_sha256"].items():
    assert hashlib.sha256((run / name).read_bytes()).hexdigest() == sha, name
prefixes = [
    ("i_core_i_cpu", "CPU"),
    ("i_core_i_xbar", "XBAR"),
    ("i_core_i_mmio", "MMIO / queues"),
    ("i_core_i_quant", "Quantizer"),
    ("i_core_i_matrix_stream", "Matrix Stream"),
    ("i_core_i_matmul", "Matrix compute"),
    ("i_core_i_vector_stream", "Vector Stream"),
    ("i_core_i_vector", "Vector compute"),
    ("i_core_i_stream", "CNN Stream"),
    ("i_core_i_cnn", "CNN compute"),
    ("i_core_i_debug", "JTAG / debug"),
    ("i_core_i_boot", "JTAG / debug"),
]
buckets = collections.defaultdict(lambda: dict(cells=0, area_um2=0.0))
sub = collections.defaultdict(float)
names = set()
gates = 0
total = 0
path = run / "reports/leaf_area.tsv"
for line in path.read_text().splitlines():
    name, cell, value = line.split("\t")
    area = float(value)
    assert name not in names and area > 0, name
    names.add(name)
    total += area
    key = "Shared / unattributed"
    if cell == "RA1SHD_2048x32M8":
        key = "SRAM"
    else:
        for prefix, group in prefixes:
            if name.startswith(prefix):
                key = group
                break
    buckets[key]["cells"] += 1
    buckets[key]["area_um2"] += area
    if cell.startswith("CKLNQ"):
        gates += 1
    if name.startswith("i_core_i_xbar/i_regfile"):
        sub["RF"] += area
    elif name.startswith("i_core_i_xbar/i_stream_routes"):
        sub["Stream FIFOs"] += area
    elif key == "XBAR":
        sub["Arbitration / response"] += area
assert abs(total / 1e6 - reference["total_area_mm2"]) < 1e-8
assert buckets["SRAM"]["cells"] == 2
assert (
    len(names)
    == json.loads((ROOT / "npu/reports/area25_area.json").read_text())["hierarchical_rows"][0][
        "cells"
    ]
)
for b in buckets.values():
    b["area_mm2"] = b["area_um2"] / 1e6
    b["percent"] = b["area_um2"] / total * 100
r = dict(
    passed=True,
    run=str(run),
    total_area_mm2=total / 1e6,
    leaf_cells=len(names),
    clock_gate_cells=gates,
    scope="Exact final mapped cell areas; conservative surviving instance-prefix attribution, not floorplan",
    attribution_rule="Each leaf assigned once by surviving original prefix. Shared, merged or unnamed cells remain unattributed; named module values are lower bounds, not a complete original RTL-module area reconstruction.",
    unattributed_percent=buckets["Shared / unattributed"]["percent"],
    buckets=buckets,
    xbar_subgroups_mm2={k: v / 1e6 for k, v in sub.items()},
    leaf_export_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
    netlist_sha256=reference["run_file_sha256"]["optimized.v"],
    rtl_sha256=reference["source_sha256"],
    hierarchy_reference_run=str(ROOT.parent / "eda-runs/20261107-area25-profile-hier"),
)
if a.hier_run:
    import subprocess, sys

    h = a.hier_run.resolve()
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (h / "launcher.log").read_text()
    assert "No unresolved references" in (h / "reports/unresolved.rpt").read_text()
    m = json.loads((h / "source_manifest.json").read_text())
    assert m["source_sha256"] == reference["source_manifest"]["source_sha256"]
    assert m["synth_period_ns"] == 18 and m["report_period_ns"] == 20 and m["clock_gating"]
    assert json.loads((h / "library_manifest.json").read_text()) == json.loads(
        (run / "library_manifest.json").read_text()
    )
    out = ROOT / "npu/reports/area18_distribution_hierarchy.json"
    subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("collect_module_area.py")),
            "--run",
            str(h),
            "--out",
            str(out),
        ],
        check=True,
    )
    hr = json.loads(out.read_text())
    assert hr["compute_boundaries_preserved"]
    xsub = collections.defaultdict(float)
    if (h / "reports/leaf_area.tsv").exists():
        sumarea = 0
        for line in (h / "reports/leaf_area.tsv").read_text().splitlines():
            name, cell, value = line.split("\t")
            value = float(value)
            sumarea += value
            if name.startswith("i_core_i_xbar/i_regfile"):
                xsub["RF"] += value / 1e6
            elif name.startswith("i_core_i_xbar/i_stream_routes"):
                xsub["Stream FIFOs"] += value / 1e6
            elif name.startswith("i_core_i_xbar/"):
                xsub["Arbitration / response"] += value / 1e6
        assert abs(sumarea / 1e6 - hr["total_area_mm2"]) < 1e-8
        assert abs(sum(xsub.values()) - hr["buckets"]["XBAR"]["area_mm2"]) < 1e-8
    qtext = (h / "reports/qor.rpt").read_text()
    import re

    timing = [
        dict(group=g, slack_ns=float(s) / 1000, tns_ns=float(t) / 1000, violations=int(n))
        for g, s, t, n in re.findall(r"^(\S+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qtext, re.M)
    ]
    assert timing and all(t["slack_ns"] >= 0 and t["violations"] == 0 for t in timing)
    smoke = []
    for path in h.glob("gls-*/result.json"):
        d = json.loads(path.read_text())
        assert d["passed"]
        for name, sha in d["sha256"].items():
            assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, name
        smoke.append(dict(suite=d["suite"], result=str(path), summaries=d["summaries"]))
    r["hierarchy_reference"] = dict(
        run=str(h),
        report=str(out.relative_to(ROOT)),
        total_area_mm2=hr["total_area_mm2"],
        difference_from_final_mm2=hr["total_area_mm2"] - r["total_area_mm2"],
        scope="Separate 18ns high-effort clock-gated synthesis with unit boundaries retained; never mix with final leaf-attributed totals",
        buckets=hr["buckets"],
        rows=hr["hierarchical_rows"],
        xbar_subgroups_mm2=dict(xsub),
        timing_groups=timing,
        gate_smoke=smoke,
    )
(ROOT / "npu/reports/area18_distribution.json").write_text(json.dumps(r, indent=2) + "\n")
for k, b in sorted(buckets.items(), key=lambda kv: -kv[1]["area_mm2"]):
    print(k, f"{b['area_mm2']:.6f}", f"{b['percent']:.2f}%")
print("XBAR", r["xbar_subgroups_mm2"])
