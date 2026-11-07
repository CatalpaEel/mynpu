"""Check current-source CNN cleanup evidence against its frozen pre-change snapshot."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--run", type=Path, required=True)
p.add_argument("--tag", default="cleanup1")
a = p.parse_args()
run = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()


def functional(name):
    folder = ROOT / "build" / name
    result = json.loads((folder / "result.json").read_text())
    assert result["passed"] and not result["changed_during_run"], folder
    for f, digest in result["sha256"].items():
        assert sha(f) == digest, f
    return {
        "result": str(folder / "result.json"),
        "result_sha256": sha(folder / "result.json"),
        "run_log_sha256": sha(folder / "run.log"),
        "passed": True,
        "summaries": result["summaries"],
    }


suites = [
    "latency",
    "layers",
    "stream",
    "cnnqueues",
    "soc",
    "jtag",
    "ops",
    "burst",
    "xbar",
    "xbarconcurrent",
    "queues",
    "dma",
]
macro = {"latency", "layers", "stream", "soc", "jtag", "ops", "burst"}
regressions = {s: functional(f"vcs-{a.tag}-{s}" + ("-macro" if s in macro else "")) for s in suites}
for depth in [1, 2]:
    regressions[f"cnnqueues_depth{depth}"] = functional(f"vcs-cleanup-depth{depth}-cnnqueues")
gates = {s: functional(f"gate-{a.tag}-{s}") for s in ["latency", "burst"]}

r = run / "asic"
manifest = json.loads((r / "source_manifest.json").read_text())
for f, digest in manifest["source_sha256"].items():
    assert sha(ROOT.parent / f) == digest, f
for f, digest in json.loads((r / "library_manifest.json").read_text()).items():
    assert sha(f) == digest, f
assert (
    manifest["effort"] == "low"
    and manifest["synth_period_ns"] == 16
    and manifest["report_period_ns"] == 20
)
assert manifest["cnn_mac_lanes"] == 9 and manifest["cnn_loop_order"] == "row"
assert all(
    manifest[k] == 16 for k in ["cnn_queue_depth", "matrix_queue_depth", "vector_queue_depth"]
)
log = (r / "launcher.log").read_text()
assert "DUAL_BANK_ASIC_SYNTH_PASS" in log and "Normal exit." in log
area = (r / "reports/area.rpt").read_text()
row = re.search(r"^npu_asic_top\s+(\d+)\s+([\d.]+)\s+([\d.]+)", area, re.M)
assert row
qor = (r / "reports/qor.rpt").read_text()
system = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
jtag = re.search(r"^jtag_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
assert system and jtag
assert float(re.search(r"^sys_clk\s+([\d.]+)\s*$", qor, re.M)[1]) == 20000
checks = {}
text = (r / "reports/check_design.rpt").read_text()
for label in [
    "Unresolved References",
    "Empty Modules",
    "Undriven Port(s)",
    "Undriven Leaf Pin(s)",
    "Multidriven Port(s)",
    "Multidriven Leaf Pin(s)",
]:
    checks[label] = int(re.search(re.escape(label) + r"\s+(\d+)", text)[1])
    assert checks[label] == 0, label
assert len(re.findall(r"(?m)^\s*RA1SHD_2048x32M8\s+\S+\s*\(", (r / "optimized.v").read_text())) == 2

before_file = run / "before/cnn_row_order_validation.json"
before = json.loads(before_file.read_text())["variants"]["row"]
# Previous reports describe the frozen pre-cleanup implementation, never current RTL.
for f, digest in before["source_manifest"]["source_sha256"].items():
    frozen = run / "before/rtl" / Path(f).name if f.startswith("npu/rtl/") else ROOT.parent / f
    assert sha(frozen) == digest, frozen
for k in [
    "effort",
    "synth_period_ns",
    "report_period_ns",
    "cnn_mac_lanes",
    "cnn_loop_order",
    "cnn_queue_depth",
    "matrix_queue_depth",
    "vector_queue_depth",
]:
    assert before["source_manifest"][k] == manifest[k], k
old_run = run.parent / "20261103-cnn-row-order/row"
for f, digest in before["reports_sha256"].items():
    assert sha(old_run / f) == digest, f
assert json.loads((old_run / "library_manifest.json").read_text()) == json.loads(
    (r / "library_manifest.json").read_text()
)
old_assets = json.loads(Path(before["functional"]["latency"]["result"]).read_text())["sha256"]
assets = {}
for f in (ROOT / "mnist/artifacts").glob("*.hex"):
    assert old_assets[str(f)] == sha(f), f
    assets[f.name] = sha(f)

latency_log = Path(regressions["latency"]["result"]).with_name("run.log").read_text()
rows = re.findall(
    r"SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)", latency_log
)
assert len(rows) == 10 and all(int(v[1]) == 40770 for v in rows)
cycles = max(int(v[3]) for v in rows)
assert cycles < 20000
inclusive = int(re.search(r"input_to_classification_cycles=(\d+)", latency_log)[1])
stream_log = Path(regressions["stream"]["result"]).with_name("run.log").read_text()
stream = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", stream_log)
assert stream

old_sources = [run / "before/rtl/npu_cnn.sv", run / "before/rtl/npu_cnn_mac.sv"]
new_sources = sorted((ROOT / "rtl").glob("npu_cnn*.sv"))


def size(files):
    return {
        "lines": sum(len(f.read_text().splitlines()) for f in files),
        "bytes": sum(f.stat().st_size for f in files),
        "files": {str(f): sha(f) for f in files},
    }


subprocess.run(
    [
        "gcc",
        "-std=c11",
        "-Wall",
        "-Werror",
        "-fsyntax-only",
        "-x",
        "c",
        "-include",
        str(ROOT / "sw/npu.h"),
        "/dev/null",
    ],
    check=True,
)
cnn_parts = {
    n: float(v) / 1e6
    for n, v in re.findall(
        r"^\s+(i_core_i_cnn_i_(?:engine|control))\s+\S+\s+\d+\s+([\d.]+)", area, re.M
    )
}
assert len(cnn_parts) == 2
cnn_area = sum(cnn_parts.values())
cell_area = float(row[2]) / 1e6
assert cell_area < 3 and float(system[1]) >= 0 and float(system[2]) == 0
assert float(jtag[1]) >= 0 and float(jtag[2]) == 0
out = {
    "scope": "Remove legacy tile/three-MAC paths, duplicate metadata and banked quant parameters; preserve CRO2 and integer semantics. No firmware changes.",
    "removed": [
        "legacy tile and three-MAC alternatives",
        "weight-hit tags/copy path",
        "duplicate Conv/FC reduction cursors",
        "banked multiplier/bias and operand-stage copies",
        "PREP loader state including FC",
        "duplicate activation addressing metadata",
        "full SRAM offsets in row-local output tags",
    ],
    "modules": {
        "npu_cnn": "port wrapper",
        "npu_cnn_pkg": "typed ABI and validation",
        "npu_cnn_control": "CSR, FIFO and accounting",
        "npu_cnn_engine": "row loading, overlap and writeback",
        "npu_cnn_mac": "nine products, row partial sums and internal Q24 pipeline",
    },
    "before": {
        "historical_report": str(before_file),
        "report_sha256": sha(before_file),
        "cell_area_mm2": before["cell_area_mm2"],
        "cnn_cell_area_mm2": before["cnn_cell_area_mm2"],
        "system_setup_slack_ns": before["system_setup_slack_ns"],
        "single_cycles": before["functional"]["latency"]["single_cycles"],
        "source_size": size(old_sources),
    },
    "after": {
        "source_size": size(new_sources),
        "cell_area_mm2": cell_area,
        "cnn_cell_area_mm2": cnn_area,
        "cnn_parts_cell_area_mm2": cnn_parts,
        "standard_cell_area_mm2": cell_area - before["sram_cell_area_mm2"],
        "sram_cell_area_mm2": before["sram_cell_area_mm2"],
        "cell_count": int(row[1]),
        "system_setup_slack_ns": float(system[1]) / 1000,
        "system_tns_ps": float(system[2]),
        "system_violating_paths": int(system[3]),
        "jtag_setup_slack_ns": float(jtag[1]) / 1000,
        "jtag_tns_ps": float(jtag[2]),
        "jtag_violating_paths": int(jtag[3]),
        "single_cycles": cycles,
        "kernel_cycles": int(rows[0][2]),
        "input_to_classification_cycles": inclusive,
        "stream_frames": int(stream[1]),
        "stream_cycles": int(stream[2]),
        "stream_cycles_per_frame": int(stream[2]) / int(stream[1]),
        "checks": checks,
        "source_manifest": manifest,
        "reports_sha256": {f.name: sha(f) for f in (r / "reports").glob("*.rpt")},
    },
    "comparison": {
        "cell_area_reduction_mm2": before["cell_area_mm2"] - cell_area,
        "cell_area_reduction_percent": 100 * (1 - cell_area / before["cell_area_mm2"]),
        "cnn_cell_area_reduction_percent": 100 * (1 - cnn_area / before["cnn_cell_area_mm2"]),
        "single_cycle_saving": before["functional"]["latency"]["single_cycles"] - cycles,
    },
    "regressions": regressions,
    "mapped_netlist": gates,
    "firmware_and_hex_assets_unchanged_sha256": assets,
    "corner": "TSMC180 TT",
    "effort": "low",
    "synthesis_period_ns": 16,
    "report_period_ns": 20,
    "mapped_functional_zero_delay": True,
    "sdf": False,
    "planned_pnr_width_um": 2000,
    "planned_pnr_height_um": 2000,
    "cell_area_budget_mm2": 3,
    "post_route_verified": False,
    "includes_pads": False,
    "collector_sha256": sha(__file__),
}
f = ROOT / "reports/cnn_cleanup_validation.json"
f.write_text(json.dumps(out, indent=2) + "\n")
(run / "validation.json").write_text(f.read_text())
print(json.dumps({k: out[k] for k in ["comparison"]}, indent=2))
print(f)
