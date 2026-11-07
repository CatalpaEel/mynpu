"""Collect XBAR per-master concurrency and CNN 3-versus-9 MAC evidence."""

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


def synth(name, tag, macs):
    r = run / name
    m = json.loads((r / "source_manifest.json").read_text())
    assert m["cnn_mac_lanes"] == macs and all(
        m[k] == 16 for k in ["cnn_queue_depth", "matrix_queue_depth", "vector_queue_depth"]
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
        "macs": macs,
        "depths": {"cnn": 16, "matrix": 16, "vector": 16},
        "queue_descriptor_bits": {"cnn": 104, "matrix": 62, "vector": 93},
        "queue_payload_bits": 16 * (104 + 62 + 93),
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
        "functional": {"latency": f, "stream": st, "layers": functional(f"vcs-{tag}-layers-macro")},
        "reports_sha256": {str(f.relative_to(r)): sha(f) for f in (r / "reports").glob("*.rpt")},
    }
    return out


variants = {str(m): synth("mac" + str(m), "xbar-mac" + str(m) + "-check", m) for m in (3, 9)}
v3 = variants["3"]
v9 = variants["9"]
assert v3["source_manifest"]["source_sha256"] == v9["source_manifest"]["source_sha256"]
for key in ["effort", "synth_period_ns", "report_period_ns"]:
    assert v3["source_manifest"][key] == v9["source_manifest"][key]
paths = {
    "xbar": "vcs-xbar-parallel-first-xbar",
    "xbar_concurrent": "vcs-xbar-parallel-final-xbarconcurrent",
    "soc": "vcs-xbar-mac9-check-soc-macro",
    "operators": "vcs-xbar-mac9-check-ops-macro",
    "jtag": "vcs-xbar-mac9-check-jtag-macro",
    "cnn_queue": "vcs-xbar-mac9-check-cnnqueues",
    "matrix_vector_queue": "vcs-all16-final-queues",
    "dma_control": "vcs-all16-final-dma",
    "burst": "vcs-xbar-mac9-check-burst-macro",
}
extra = {n: functional(folder) for n, folder in paths.items()}
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
old = run / "before/fifo16_validation.json"
history = json.loads(old.read_text())
burst_log = (Path(extra["burst"]["result"]).parent / "run.log").read_text()
burst = re.search(r"BURST PASS .*?submit_cycles=(\d+) total_cycles=(\d+)", burst_log)
assert burst
extra["burst"].update(submit_cycles=int(burst[1]), total_cycles=int(burst[2]))
gate = functional("gate-xbar-mac9")
gate.update(samples=1, zero_delay=True, sdf=False, timing_checks_disabled=True)
gateburst = functional("gate-xbar-mac9-burst")
gateburst.update(zero_delay=True, sdf=False, timing_checks_disabled=True)
out = {
    "scope": "XBAR delayed-MMIO owner-only exclusion; other masters access SRAM concurrently. CNN defaults to 9 parallel 3x3 taps, software still schedules rows/channels. All compute queues depth16.",
    "variants": variants,
    "regressions": extra,
    "mapped_inference": gate,
    "mapped_burst": gateburst,
    "benchmark_unchanged_sha256": benchmark,
    "historical_original_xbar_mac3": {
        "file": str(old),
        "sha256": sha(old),
        "single_cycles": history["variants"]["all16"]["functional"]["latency"]["single_cycles"],
        "cell_area_mm2": history["variants"]["all16"]["cell_area_mm2"],
        "note": "Different source snapshot; area comparison is historical, not same-source isolation",
    },
    "comparison": {
        "batch_total_cycle_saving": history["burst_workloads"]["16"]["total_cycles"]
        - extra["burst"]["total_cycles"],
        "xbar_only_cycle_saving": 27159 - v3["functional"]["latency"]["single_cycles"],
        "mac9_extra_cycle_saving": v3["functional"]["latency"]["single_cycles"]
        - v9["functional"]["latency"]["single_cycles"],
        "mac9_cell_area_delta_mm2": v9["cell_area_mm2"] - v3["cell_area_mm2"],
        "combined_cycle_saving": 27159 - v9["functional"]["latency"]["single_cycles"],
        "under_20k": v9["functional"]["latency"]["single_cycles"] < 20000,
    },
    "planned_pnr_width_um": 2000,
    "planned_pnr_height_um": 2000,
    "cell_area_budget_mm2": 3,
    "corner": "TSMC180 TT",
    "effort": v9["source_manifest"]["effort"],
    "synthesis_optimized_period_ns": 16,
    "report_period_ns": 20,
    "post_route_verified": False,
}
f = ROOT / "reports/xbar_mac9_validation.json"
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
