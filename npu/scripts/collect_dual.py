"""Collect completed Genus and VCS evidence; reject stale RTL, assets or libraries."""

import argparse, hashlib, json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument(
    "--profile", choices=["dual", "jtag", "operators", "independent", "cnn-row"], default="dual"
)
p.add_argument("--run", required=True, type=Path)
p.add_argument("--out", type=Path)
a = p.parse_args()
run = a.run.resolve()
if a.out is None:
    a.out = (
        ROOT
        / "reports"
        / {
            "dual": "dual_bank_validation.json",
            "jtag": "jtag_validation.json",
            "operators": "operators_validation.json",
            "independent": "independent_units_ppa.json",
            "cnn-row": "cnn_row_ppa.json",
        }[a.profile]
    )
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
manifest = json.loads((run / "source_manifest.json").read_text())
source_root = Path(manifest["source_root"])
changed = [name for name, h in manifest["source_sha256"].items() if sha(source_root / name) != h]
assert not changed, changed
for name, h in json.loads((run / "library_manifest.json").read_text()).items():
    assert sha(name) == h, name
text = (run / "launcher.log").read_text()
assert "DUAL_BANK_ASIC_SYNTH_PASS" in text and "Normal exit." in text, (
    "Synthesis has not completed normally"
)
area = (run / "reports/area.rpt").read_text()
m = re.search(r"^npu_asic_top\s+(\d+)\s+([\d.]+)\s+([\d.]+)", area, re.M)
assert m
qor = (run / "reports/qor.rpt").read_text()
q = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
assert q
period = float(re.search(r"^sys_clk\s+([\d.]+)\s*$", qor, re.M)[1]) / 1000
assert period == manifest["report_period_ns"]
check = (run / "reports/check_design.rpt").read_text()
checks = {}
for label in [
    "Unresolved References",
    "Empty Modules",
    "Undriven Port(s)",
    "Undriven Leaf Pin(s)",
    "Multidriven Port(s)",
    "Multidriven Leaf Pin(s)",
    "Undriven hierarchical pin(s)",
]:
    c = re.search(re.escape(label) + r"\s+(\d+)", check)
    assert c, label
    checks[label] = int(c[1])
    if label != "Undriven hierarchical pin(s)":
        assert checks[label] == 0, (label, checks[label])
net = (run / "optimized.v").read_text()
macro_count = len(re.findall(r"(?m)^\s*RA1SHD_2048x32M8\s+\S+\s*\(", net))
assert macro_count == 2, macro_count
libmeta = json.loads((run / "library_manifest.json").read_text())
lef = next(Path(x) for x in libmeta if x.endswith(".vclef"))
size = re.search(r"\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef.read_text())
assert size
macro_area = 2 * float(size[1]) * float(size[2])
total = float(m[2])
timing = (run / "reports/timing.rpt").read_text()
synthq = (run / "reports/optimized_synth_clock_qor.rpt").read_text()
sq = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", synthq, re.M)
assert sq
synthesis = dict(
    tool="Genus 19.17",
    corner="TSMC180 TT",
    cell_area_um2=total,
    cell_area_mm2=total / 1e6,
    sram_macro_count=macro_count,
    sram_area_mm2=macro_area / 1e6,
    standard_cell_area_mm2=(total - macro_area) / 1e6,
    cell_count=int(m[1]),
    net_area_excluded_um2=float(m[3]),
    report_period_ns=period,
    setup_slack_ns=float(q[1]) / 1000,
    tns_ps=float(q[2]),
    violating_paths=int(q[3]),
    optimized_at_period_ns=manifest["synth_period_ns"],
    optimized_clock_setup_slack_ns=float(sq[1]) / 1000,
    optimized_clock_tns_ps=float(sq[2]),
    critical_startpoint=re.search(r"Startpoint:\s*(.*)", timing)[1],
    critical_endpoint=re.search(r"Endpoint:\s*(.*)", timing)[1],
    checks=checks,
    post_route_verified=False,
    includes_pads=False,
)
if a.profile != "dual":
    jq = re.search(r"^jtag_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
    assert jq
    jp = float(re.search(r"^jtag_clk\s+([\d.]+)\s*$", qor, re.M)[1]) / 1000
    assert jp == 100
    synthesis.update(
        jtag_period_ns=jp,
        jtag_setup_slack_ns=float(jq[1]) / 1000,
        jtag_tns_ps=float(jq[2]),
        jtag_violating_paths=int(jq[3]),
    )
paths = {
    "xbar": "vcs-dual-final-xbar",
    "queues": "vcs-dual-final-queues",
    "dma": "vcs-dual-final-dma",
    "soc_macro": "vcs-dual-final-soc-macro",
    "latency_macro": "vcs-dual-final-latency-macro",
    "layers_macro": "vcs-dual-tail-layers-macro",
    "stream": "vcs-dual-v8-stream",
    "mapped_gate": "gate-dual-final",
}
if a.profile == "jtag":
    paths = {
        "xbar": "vcs-jtag-final-xbar",
        "queues": "vcs-dual-final-queues",
        "dma": "vcs-dual-final-dma",
        "soc": "vcs-jtag-v1-soc",
        "jtag_macro": "vcs-jtag-final3-jtag-macro",
        "latency_macro": "vcs-jtag-final-latency-macro",
        "layers_macro": "vcs-jtag-final-layers-macro",
        "stream": "vcs-jtag-v1-stream",
        "mapped_gate": "gate-jtag-final",
        "mapped_jtag": "gate-jtag-pins",
    }
if a.profile == "operators":
    paths = {
        "xbar": "vcs-jtag-final-xbar",
        "dma": "vcs-dual-final-dma",
        "queues": "vcs-operators-final-queues",
        "soc": "vcs-operators-final-soc",
        "operators_macro": "vcs-operators-final-ops-macro",
        "jtag_macro": "vcs-operators-final-jtag-macro",
        "latency_macro": "vcs-operators-final-latency-macro",
        "layers_macro": "vcs-operators-final-layers-macro",
        "stream": "vcs-operators-final-stream",
        "mapped_gate": "gate-operators-final",
        "mapped_ops": "gate-operators-ops",
    }
if a.profile == "independent":
    paths = {
        "xbar": "vcs-independent-final-xbar",
        "queues": "vcs-independent-final-queues",
        "dma": "vcs-independent-final-dma",
        "soc": "vcs-independent-final-soc-macro",
        "operators_macro": "vcs-independent-final-ops-macro",
        "jtag_macro": "vcs-independent-final2-jtag-macro",
        "latency_macro": "vcs-independent-final-latency-macro",
        "layers_macro": "vcs-independent-final-layers-macro",
        "stream": "vcs-independent-final-stream-macro",
        "mapped_gate": "gate-independent-final",
        "mapped_ops": "gate-independent-ops",
        "mapped_jtag": "gate-independent-jtag",
    }
if a.profile == "cnn-row":
    paths = {
        "xbar": "vcs-cnn-row-final-xbar",
        "queues": "vcs-cnn-row-final-queues",
        "dma": "vcs-cnn-row-final-dma",
        "soc": "vcs-cnn-row-final-soc-macro",
        "operators_macro": "vcs-cnn-row-final-ops-macro",
        "jtag_macro": "vcs-cnn-row-final-jtag-macro",
        "latency_macro": "vcs-cnn-row-final-latency-macro",
        "layers_macro": "vcs-cnn-row-final-layers-macro",
        "stream": "vcs-cnn-row-final-stream-macro",
        "mapped_gate": "gate-cnn-row-final",
        "mapped_ops": "gate-cnn-row-ops",
        "mapped_jtag": "gate-cnn-row-jtag",
    }
functional = {}
for name, folder in paths.items():
    result = ROOT / "build" / folder / "result.json"
    j = json.loads(result.read_text())
    assert j["passed"] and not j["changed_during_run"], str(result)
    for f, h in j["sha256"].items():
        assert sha(f) == h, (name, f)
    log = (result.parent / "run.log").read_text()
    assert not re.search(r"Fatal:|Warning-\[STASKW|Illegal entry|Not enough words", log), str(
        result
    )
    functional[name] = {
        "passed": True,
        "result": str(result),
        "result_sha256": sha(result),
        "summaries": j["summaries"],
    }
    if name in ["mapped_gate", "mapped_jtag", "mapped_ops"]:
        functional[name].update(
            samples=j["samples"], zero_delay=True, sdf=False, timing_checks_disabled=True
        )
    if name == "latency_macro":
        rows = re.findall(
            r"SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)", log
        )
        assert len(rows) == 10
        if a.profile != "cnn-row":
            assert all(int(row[3]) < 20000 for row in rows)
        functional[name].update(
            samples=len(rows),
            cycles_min=min(int(x[3]) for x in rows),
            cycles_max=max(int(x[3]) for x in rows),
            kernel_cycles=int(rows[0][2]),
            input_dma_cycles=int(re.search(r"ingress_cycles=(\d+)", log)[1]),
            input_to_classification_cycles=int(
                re.search(r"input_to_classification_cycles=(\d+)", log)[1]
            ),
        )
    if name == "stream":
        f = re.search(
            r"STREAM PASS frames=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)",
            log,
        )
        assert f
        functional[name].update(
            frames=int(f[1]), cycles_total=int(f[4]), cycles_per_frame=int(f[4]) / int(f[1])
        )
        if a.profile != "cnn-row":
            assert functional[name]["cycles_per_frame"] < 20000
# Verify this task did not change benchmark parameters, inputs, or golden values.
benchmark = {}
for f in (
    list((ROOT / "mnist/artifacts").glob("input*.hex"))
    + list((ROOT / "mnist/artifacts").glob("gold*.hex"))
    + [ROOT / "mnist/artifacts/params.hex"]
):
    rel = str(f.relative_to(ROOT.parent))
    original = subprocess.check_output(["git", "show", "c101c29:" + rel], cwd=ROOT)
    assert hashlib.sha256(original).hexdigest() == sha(f), rel
    benchmark[rel] = sha(f)
summary = {
    "base_commit": manifest["git_commit"],
    "branch": manifest["branch"],
    "scope": manifest["scope"],
    "source_sha256": manifest["source_sha256"],
    "source_changed": changed,
    "synthesis": synthesis,
    "functional": functional,
    "benchmark_unchanged_sha256": benchmark,
    "profile": a.profile,
    "synthesis_effort": manifest["effort"],
    "reports_sha256": {str(f.relative_to(run)): sha(f) for f in (run / "reports").glob("*.rpt")},
    "baseline": {
        "cell_area_mm2": 1.364122208,
        "sram_macros": 1,
        "clock_period_ns": 20,
        "setup_slack_ns": 0.0001,
        "single_cycles": 41830,
        "stream_cycles_per_frame": 42974.55,
    },
    "single_cycle_reduction_percent": 100 * (1 - functional["latency_macro"]["cycles_max"] / 41830),
    "route_or_board_test_performed": False,
}
if a.profile in ["operators", "independent", "cnn-row"]:
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
    summary["operator_abi"] = {
        "major": 1,
        "minor": 0,
        "gemm_flags_mask": 31,
        "vector_opcode_mask": 65535,
        "cnn_opcode_mask": 15,
        "header_sha256": sha(ROOT / "sw/npu.h"),
        "header_validation": "GCC C11 syntax only; RV32 hardware functional tests use MMIO testbench and existing CPU programs",
    }
    summary["previous_jtag_snapshot"] = {
        "cell_area_mm2": 2.084308839,
        "synthesis_effort": "medium",
        "single_cycles": 18726,
        "comparison_note": "Effort differs; area delta is not a controlled same-effort operator-only comparison",
    }
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(summary, indent=2) + "\n")
(run / "validation.json").write_text(json.dumps(summary, indent=2) + "\n")
print(
    json.dumps(
        {
            "synthesis": synthesis,
            "single": functional["latency_macro"]["cycles_max"],
            "stream": functional["stream"]["cycles_per_frame"],
            "output": str(a.out),
        },
        indent=2,
    )
)
