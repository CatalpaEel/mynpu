"""Collect same-source all16 versus CNN8/matrix2/vector2 synthesis and workloads."""

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
    return {
        "result": str(f),
        "result_sha256": sha(f),
        "run_log_sha256": sha(f.parent / "run.log"),
        "passed": True,
        "summaries": j["summaries"],
    }


def synth(name, tag, cnn_depth, mat_depth, vec_depth):
    r = run / name
    m = json.loads((r / "source_manifest.json").read_text())
    assert (m["cnn_queue_depth"], m["matrix_queue_depth"], m["vector_queue_depth"]) == (
        cnn_depth,
        mat_depth,
        vec_depth,
    )
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
        assert checks[label] == 0, (name, label)
    libmeta = json.loads((r / "library_manifest.json").read_text())
    lef = next(Path(n) for n in libmeta if n.endswith(".vclef"))
    size = re.search(r"\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef.read_text())
    macro_area = 2 * float(size[1]) * float(size[2]) / 1e6
    net = (r / "optimized.v").read_text()
    assert len(re.findall(r"(?m)^\s*RA1SHD_2048x32M8\s+\S+\s*\(", net)) == 2
    f = functional(f"vcs-{tag}-latency-macro")
    st = functional(f"vcs-{tag}-stream-macro")
    text = (Path(f["result"]).parent / "run.log").read_text()
    rows = re.findall(
        r"SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)", text
    )
    assert len(rows) == 10 and all(int(x[1]) == 40770 for x in rows)
    profiles = re.findall(
        r"FIFO_PROFILE sample=\d+ cnn_pending_peak=(\d+) packed_word_peak=(\d+)", text
    )
    assert len(profiles) == 10
    f.update(
        cnn_pending_peak=max(int(x[0]) for x in profiles),
        packed_word_peak=max(int(x[1]) for x in profiles),
    )
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
        "depths": {"cnn": cnn_depth, "matrix": mat_depth, "vector": vec_depth},
        "queue_descriptor_bits": {"cnn": 104, "matrix": 62, "vector": 93},
        "queue_payload_bits": 104 * cnn_depth + 62 * mat_depth + 93 * vec_depth,
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
            "cnn_queue": functional(f"vcs-{tag}-cnnqueues"),
            "matrix_vector_queue": functional(f"vcs-{tag}-queues"),
        },
        "reports_sha256": {str(f.relative_to(r)): sha(f) for f in (r / "reports").glob("*.rpt")},
    }
    return out


variants = {
    "baseline": synth("baseline", "all16-baseline", 8, 2, 2),
    "all16": synth("all16", "all16-final", 16, 16, 16),
}
b = variants["baseline"]
v = variants["all16"]
assert b["source_manifest"]["source_sha256"] == v["source_manifest"]["source_sha256"]
for key in ["effort", "synth_period_ns", "report_period_ns"]:
    assert b["source_manifest"][key] == v["source_manifest"][key]
extra = {
    suite: functional(
        "vcs-all16-final-" + suite + ("-macro" if suite in ["layers", "ops", "soc", "jtag"] else "")
    )
    for suite in ["layers", "ops", "soc", "jtag", "xbar", "dma"]
}
bursts = {}
for d in [2, 16]:
    item = functional(f"vcs-burst{d}-burst-macro")
    text = (Path(item["result"]).parent / "run.log").read_text()
    match = re.search(
        r"BURST PASS matrix_depth=(\d+) vector_depth=(\d+) matrix_jobs=16 vector_jobs=16 submit_cycles=(\d+) total_cycles=(\d+) matrix_pending_peak=(\d+) vector_pending_peak=(\d+)",
        text,
    )
    assert match and int(match[1]) == d and int(match[2]) == d
    item.update(
        submit_cycles=int(match[3]),
        total_cycles=int(match[4]),
        matrix_pending_peak=int(match[5]),
        vector_pending_peak=int(match[6]),
        producer="Host MMIO task submission; not an RV32 CPU benchmark",
    )
    bursts[str(d)] = item
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
gate = functional("gate-all16-final")
gate.update(samples=1, zero_delay=True, sdf=False, timing_checks_disabled=True)
out = {
    "scope": "All three compute task FIFOs depth16; output packing and CPU/JTAG protocol buffering unchanged",
    "variants": variants,
    "all16_regressions": extra,
    "burst_workloads": bursts,
    "mapped_inference": gate,
    "benchmark_unchanged_sha256": benchmark,
    "comparison": {
        "cell_area_delta_mm2": v["cell_area_mm2"] - b["cell_area_mm2"],
        "cell_area_delta_percent": 100 * (v["cell_area_mm2"] / b["cell_area_mm2"] - 1),
        "single_cycle_saving": b["functional"]["latency"]["single_cycles"]
        - v["functional"]["latency"]["single_cycles"],
        "stream_cycle_saving_per_frame": b["functional"]["stream"]["cycles_per_frame"]
        - v["functional"]["stream"]["cycles_per_frame"],
        "mnist_under_20k": v["functional"]["latency"]["single_cycles"] < 20000,
        "burst_submission_cycle_saving": bursts["2"]["submit_cycles"]
        - bursts["16"]["submit_cycles"],
        "burst_completion_cycle_saving": bursts["2"]["total_cycles"] - bursts["16"]["total_cycles"],
    },
    "corner": "TSMC180 TT",
    "effort": v["source_manifest"]["effort"],
    "synthesis_optimized_period_ns": 16,
    "report_period_ns": 20,
    "post_route_verified": False,
}
if (ROOT / "build/gate-all16-burst/result.json").exists():
    out["mapped_burst"] = functional("gate-all16-burst")
    out["mapped_burst"].update(zero_delay=True, sdf=False, timing_checks_disabled=True)
f = ROOT / "reports/fifo16_validation.json"
f.write_text(json.dumps(out, indent=2) + "\n")
(run / "validation.json").write_text(json.dumps(out, indent=2) + "\n")
print(
    json.dumps(
        {
            "output": str(f),
            "comparison": out["comparison"],
            "variants": {
                n: {k: x[k] for k in ["cell_area_mm2", "system_setup_slack_ns"]}
                for n, x in variants.items()
            },
        },
        indent=2,
    )
)
