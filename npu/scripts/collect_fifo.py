"""Collect same-source depth-2/depth-8 synthesis and current functional evidence."""

import argparse, hashlib, json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--run", type=Path, required=True)
a = p.parse_args()
run = a.run.resolve()
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def functional(folder):
    f = ROOT / "build" / folder / "result.json"
    j = json.loads(f.read_text())
    assert j["passed"] and not j["changed_during_run"], str(f)
    for n, h in j["sha256"].items():
        assert sha(n) == h, n
    return {"result": str(f), "result_sha256": sha(f), "passed": True, "summaries": j["summaries"]}


def synth(depth):
    r = run / f"safe-depth{depth}"
    m = json.loads((r / "source_manifest.json").read_text())
    assert m["cnn_queue_depth"] == depth
    for n, h in m["source_sha256"].items():
        assert sha(ROOT.parent / n) == h, n
    for n, h in json.loads((r / "library_manifest.json").read_text()).items():
        assert sha(n) == h, n
    log = (r / "launcher.log").read_text()
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in log and "Normal exit." in log
    area = (r / "reports/area.rpt").read_text()
    qor = (r / "reports/qor.rpt").read_text()
    row = re.search(r"^npu_asic_top\s+(\d+)\s+([\d.]+)\s+([\d.]+)", area, re.M)
    assert row
    sq = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
    assert sq
    jq = re.search(r"^jtag_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
    assert jq
    period = float(re.search(r"^sys_clk\s+([\d.]+)\s*$", qor, re.M)[1]) / 1000
    assert period == 20
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
        assert checks[label] == 0, (depth, label)
    libmeta = json.loads((r / "library_manifest.json").read_text())
    lef = next(Path(n) for n in libmeta if n.endswith(".vclef"))
    size = re.search(r"\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef.read_text())
    macro_area = 2 * float(size[1]) * float(size[2]) / 1e6
    net = (r / "optimized.v").read_text()
    assert len(re.findall(r"(?m)^\s*RA1SHD_2048x32M8\s+\S+\s*\(", net)) == 2
    f = functional(f"vcs-fifo{depth}-safe-latency-macro")
    st = functional(f"vcs-fifo{depth}-safe-stream-macro")
    text = (Path(f["result"]).parent / "run.log").read_text()
    rows = re.findall(
        r"SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)", text
    )
    assert len(rows) == 10 and all(int(x[1]) == 40770 for x in rows)
    f.update(
        single_cycles=max(int(x[3]) for x in rows),
        kernel_cycles=int(rows[0][2]),
        input_to_classification_cycles=int(
            re.search(r"input_to_classification_cycles=(\d+)", text)[1]
        ),
    )
    text = (Path(st["result"]).parent / "run.log").read_text()
    match = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", text)
    assert match
    st.update(
        frames=int(match[1]),
        total_cycles=int(match[2]),
        cycles_per_frame=int(match[2]) / int(match[1]),
    )
    timing = (r / "reports/timing.rpt").read_text()
    cnn = re.search(r"^\s+i_core_i_cnn\s+\S+\s+\d+\s+([\d.]+)", area, re.M)
    out = {
        "depth": depth,
        "queue_descriptor_bits": 104,
        "queue_payload_bits": 104 * depth,
        "source_manifest": m,
        "cell_area_mm2": float(row[2]) / 1e6,
        "cell_count": int(row[1]),
        "sram_cell_area_mm2": macro_area,
        "standard_cell_area_mm2": float(row[2]) / 1e6 - macro_area,
        "cell_area_under_3mm2": float(row[2]) < 3000000,
        "cnn_cell_area_mm2": float(cnn[1]) / 1e6 if cnn else None,
        "system_period_ns": period,
        "system_setup_slack_ns": float(sq[1]) / 1000,
        "system_tns_ps": float(sq[2]),
        "system_violating_paths": int(sq[3]),
        "jtag_setup_slack_ns": float(jq[1]) / 1000,
        "jtag_tns_ps": float(jq[2]),
        "jtag_violating_paths": int(jq[3]),
        "critical_startpoint": re.search(r"Startpoint:\s*(.*)", timing)[1],
        "critical_endpoint": re.search(r"Endpoint:\s*(.*)", timing)[1],
        "checks": checks,
        "sram_macro_count": 2,
        "includes_pads": False,
        "physical_placement_routing_completed": False,
        "functional": {
            "latency": f,
            "stream": st,
            "queue": functional(f"vcs-fifo{depth}-safe-cnnqueues"),
        },
        "reports_sha256": {str(f.relative_to(r)): sha(f) for f in (r / "reports").glob("*.rpt")},
    }
    return out


variants = {str(d): synth(d) for d in (2, 8)}
a2 = variants["2"]
a8 = variants["8"]
assert a2["source_manifest"]["source_sha256"] == a8["source_manifest"]["source_sha256"]
for key in ["effort", "synth_period_ns", "report_period_ns"]:
    assert a2["source_manifest"][key] == a8["source_manifest"][key]
extra = {
    s: functional(
        ("vcs-fifo8-safe-" if s in ["layers", "ops", "soc", "jtag"] else "vcs-fifo8-final-")
        + s
        + ("-macro" if s in ["layers", "ops", "soc", "jtag"] else "")
    )
    for s in ["layers", "ops", "soc", "jtag", "xbar", "queues", "dma"]
}
benchmark = {}
for f in (
    list((ROOT / "mnist/artifacts").glob("input*.hex"))
    + list((ROOT / "mnist/artifacts").glob("gold*.hex"))
    + [ROOT / "mnist/artifacts/params.hex"]
):
    rel = str(f.relative_to(ROOT.parent))
    base = subprocess.check_output(["git", "show", "c101c29:" + rel], cwd=ROOT)
    assert hashlib.sha256(base).hexdigest() == sha(f), rel
    benchmark[rel] = sha(f)
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
out = {
    "scope": "Independent CNN row-command FIFO depth comparison; matrix/vector remain depth 2",
    "variants": variants,
    "depth8_regressions": extra,
    "benchmark_unchanged_sha256": benchmark,
    "comparison": {
        "cell_area_delta_mm2": a8["cell_area_mm2"] - a2["cell_area_mm2"],
        "cell_area_delta_percent": 100 * (a8["cell_area_mm2"] / a2["cell_area_mm2"] - 1),
        "single_cycle_saving": a2["functional"]["latency"]["single_cycles"]
        - a8["functional"]["latency"]["single_cycles"],
        "depth8_single_under_20k": a8["functional"]["latency"]["single_cycles"] < 20000,
    },
    "synthesis_only": True,
    "corner": "TSMC180 TT",
    "mapping_effort": a8["source_manifest"]["effort"],
    "clock_optimized_at_ns": a8["source_manifest"]["synth_period_ns"],
    "clock_reported_at_ns": 20,
}
out["mapped_inference"] = functional("gate-fifo8-safe")
out["mapped_inference"].update(samples=1, zero_delay=True, sdf=False, timing_checks_disabled=True)
f = ROOT / "reports/cnn_fifo_validation.json"
f.write_text(json.dumps(out, indent=2) + "\n")
(run / "validation.json").write_text(json.dumps(out, indent=2) + "\n")
print(
    json.dumps(
        {
            "output": str(f),
            "comparison": out["comparison"],
            "variants": {
                d: {
                    k: v[k] for k in ["cell_area_mm2", "system_setup_slack_ns", "cnn_cell_area_mm2"]
                }
                for d, v in variants.items()
            },
        },
        indent=2,
    )
)
