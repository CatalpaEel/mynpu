"""Audit area/timing against the unchanged-function area25 regressions."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--comparisons", type=Path, nargs="*", default=[])
a = p.parse_args()
run = a.run.resolve()
functional = json.loads((ROOT / "npu/reports/area25_validation.json").read_text())
assert functional["passed"]
manifest = json.loads((run / "source_manifest.json").read_text())
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text()
assert "No unresolved references" in (run / "reports/unresolved.rpt").read_text()
for name, sha in manifest["source_sha256"].items():
    if name.startswith("npu/rtl/"):
        assert sha == functional["source_sha256"][name], name
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha, name
    frozen = run / "inputs" / name
    if frozen.exists():
        assert hashlib.sha256(frozen.read_bytes()).hexdigest() == sha, name
sys.path.insert(0, str(ROOT / "npu/scripts"))
from sim_sources import macro_wrapper

assert (run / "inputs/npu_asic_top.sv").read_text() == macro_wrapper(
    (ROOT / "npu/rtl/top/npu_soc.sv").read_text(), top="npu_asic_top"
)
if "seed_db" in manifest:
    assert (
        hashlib.sha256(Path(manifest["seed_db"]).read_bytes()).hexdigest()
        == manifest["seed_db_sha256"]
    )
for name, sha in json.loads((run / "library_manifest.json").read_text()).items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, name
out = ROOT / "npu/reports/area25_area.json"
subprocess.run(
    [
        sys.executable,
        str(Path(__file__).with_name("collect_module_area.py")),
        "--run",
        str(run),
        "--out",
        str(out),
    ],
    check=True,
)
area = json.loads(out.read_text())
baseline = json.loads((ROOT / "npu/reports/streams_optimized_area_flat.json").read_text())
qor = (run / "reports/qor.rpt").read_text()
# Check clock-gating enable groups as well as sys_clk and jtag_clk.
timing = []
for match in re.finditer(r"^(\S+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M):
    timing.append(
        dict(
            group=match[1],
            slack_ns=float(match[2]) / 1000,
            tns_ns=float(match[3]) / 1000,
            violations=int(match[4]),
        )
    )
assert any(t["group"] == "sys_clk" for t in timing)
clock_gates = re.findall(r"\bCKLNQ\w*BWP7T\s+", (run / "optimized.v").read_text())
r = dict(
    passed=True,
    rtl_checkpoint="bdc43c0",
    run=str(run),
    source_manifest=manifest,
    includes_two_sram_macros=True,
    pads_included=False,
    pnr_performed=False,
    scope=f"TSMC180 TT Genus synthesis;{manifest['synth_period_ns']:g}ns optimization/{manifest['report_period_ns']:g}ns reporting; no PAD/CTS/routing overhead",
    total_area_mm2=area["total_area_mm2"],
    standard_cell_area_mm2=area["standard_cell_area_mm2"],
    before_area_mm2=baseline["total_area_mm2"],
    saved_mm2=baseline["total_area_mm2"] - area["total_area_mm2"],
    saved_percent=(1 - area["total_area_mm2"] / baseline["total_area_mm2"]) * 100,
    target_area_mm2=2.5,
    target_area_met=area["total_area_mm2"] <= 2.5,
    timing_groups=timing,
    setup_target_met=all(t["slack_ns"] >= 0 and t["violations"] == 0 for t in timing),
    extracted_library_clock_gates=len(clock_gates),
    rtl_regressions=len(functional["cases"]),
    inference_cycles=functional["inference_cycles"],
    source_sha256=functional["source_sha256"],
    buckets=area["buckets"],
    bucket_note="Hierarchy-only attribution; high-effort ungrouping moves some compute cells into Top/core glue. Use whole-chip total for comparison.",
    run_file_sha256={
        name: hashlib.sha256((run / name).read_bytes()).hexdigest()
        for name in ["synth.tcl", "synth.sdc", "report.sdc", "optimized.v", "optimized.db"]
    },
    gate_smoke=[],
    comparisons=[],
)
for path in sorted(run.glob("gls-*/result.json")):
    d = json.loads(path.read_text())
    assert d["passed"], path
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (path, name)
    r["gate_smoke"].append(
        dict(result=str(path), suite=d["suite"], scope=d["scope"], summaries=d["summaries"])
    )
for path in a.comparisons:
    trial = path.resolve()
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (trial / "launcher.log").read_text(), trial
    m = json.loads((trial / "source_manifest.json").read_text())
    row = next(
        l
        for l in (trial / "reports/area.rpt").read_text().splitlines()
        if l.startswith("npu_asic_top ")
    )
    ta = float(row.split()[2]) / 1e6
    slack = (
        float(
            re.search(
                r"^sys_clk\s+([-\d.]+)\s+[-\d.]+\s+\d+\s*$",
                (trial / "reports/qor.rpt").read_text(),
                re.M,
            )[1]
        )
        / 1000
    )
    r["comparisons"].append(
        dict(
            run=str(trial),
            area_mm2=ta,
            sys_setup_slack_ns=slack,
            effort=m["effort"],
            optimization_period_ns=m["synth_period_ns"],
            same_rtl_as_selected=m["source_sha256"] == manifest["source_sha256"],
        )
    )
assert r["setup_target_met"]
(ROOT / "npu/reports/area25_area_validation.json").write_text(json.dumps(r, indent=2) + "\n")
print(
    json.dumps(
        {k: v for k, v in r.items() if k not in ["source_manifest", "source_sha256", "buckets"]},
        indent=2,
    )
)
