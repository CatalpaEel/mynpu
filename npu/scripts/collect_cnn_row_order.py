"""Collect same-source tile-versus-row-stationary CNN loop evidence."""

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


def synth(name, tag, order):
    r = run / name
    m = json.loads((r / "source_manifest.json").read_text())
    assert (
        m["cnn_mac_lanes"] == 9
        and m["cnn_loop_order"] == order
        and all(m[k] == 16 for k in ["cnn_queue_depth", "matrix_queue_depth", "vector_queue_depth"])
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
    memory = re.findall(
        r"MEMORY_PROFILE sample=\d+ weight_reads=(\d+) activation_reads=(\d+) quant_reads=(\d+) output_words=(\d+) request_stalls=(\d+) tile_waits=(\d+)",
        text,
    )
    assert len(memory) == 10
    keys = [
        "weight_reads",
        "activation_reads",
        "quant_reads",
        "output_words",
        "request_stalls",
        "tile_waits",
    ]
    f["memory_profile"] = {k: int(memory[0][i]) for i, k in enumerate(keys)}
    assert all(tuple(map(int, row)) == tuple(map(int, memory[0])) for row in memory)

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
        "macs": 9,
        "loop_order": order,
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


variants = {
    "tile": synth("tile", "row-order-baseline", "tile"),
    "row": synth("row", "row-order-final", "row"),
}
b = variants["tile"]
v = variants["row"]
assert b["source_manifest"]["source_sha256"] == v["source_manifest"]["source_sha256"]
for key in ["effort", "synth_period_ns", "report_period_ns", "cnn_mac_lanes"]:
    assert b["source_manifest"][key] == v["source_manifest"][key]
assert v["functional"]["latency"]["single_cycles"] < 20000
extra = {
    suite: functional(
        "vcs-row-order-final-"
        + suite
        + ("-macro" if suite in ["soc", "jtag", "ops", "burst"] else "")
    )
    for suite in [
        "xbar",
        "xbarconcurrent",
        "cnnqueues",
        "queues",
        "dma",
        "soc",
        "jtag",
        "ops",
        "burst",
    ]
}
extra["mac3_row_compatibility"] = functional("vcs-row-order-mac3-layers-macro")
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
previous = json.loads((run / "before/xbar_mac9_validation.json").read_text())
old_result = Path(previous["variants"]["9"]["functional"]["latency"]["result"])
old_hashes = json.loads(old_result.read_text())["sha256"]
firmware_assets = {}
for f in (ROOT / "mnist/artifacts").glob("*.hex"):
    assert old_hashes.get(str(f)) == sha(f), f
    firmware_assets[f.name] = sha(f)
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
gate = functional("gate-row-order-final")
gate.update(
    samples=1,
    zero_delay=True,
    sdf=False,
    timing_checks_disabled=True,
    performance_limit_cycles=20000,
)
gateburst = functional("gate-row-order-burst")
gateburst.update(zero_delay=True, sdf=False, timing_checks_disabled=True)
pb = b["functional"]["latency"]["memory_profile"]
pv = v["functional"]["latency"]["memory_profile"]
out = {
    "scope": "CNN input-channel outer and output-X inner; full-row activation/partial sums; row FIFO ABI/software unchanged. No inter-row weight persistence. XBAR concurrency and nine MACs retained.",
    "variants": variants,
    "regressions": extra,
    "mapped_inference": gate,
    "mapped_burst": gateburst,
    "software_header_sha256": sha(ROOT / "sw/npu.h"),
    "header_validation": "GCC C11 syntax only; hardware uses unchanged RV32 firmware images",
    "benchmark_unchanged_sha256": benchmark,
    "firmware_and_hex_assets_unchanged_sha256": firmware_assets,
    "comparison": {
        "single_cycle_saving": b["functional"]["latency"]["single_cycles"]
        - v["functional"]["latency"]["single_cycles"],
        "single_cycle_reduction_percent": 100
        * (
            1
            - v["functional"]["latency"]["single_cycles"]
            / b["functional"]["latency"]["single_cycles"]
        ),
        "cell_area_delta_mm2": v["cell_area_mm2"] - b["cell_area_mm2"],
        "cell_area_delta_percent": 100 * (v["cell_area_mm2"] / b["cell_area_mm2"] - 1),
        "weight_read_saving": pb["weight_reads"] - pv["weight_reads"],
        "activation_read_saving": pb["activation_reads"] - pv["activation_reads"],
        "under_20k_excluding_ingress": v["functional"]["latency"]["single_cycles"] < 20000,
        "under_20k_including_ingress": v["functional"]["latency"]["input_to_classification_cycles"]
        < 20000,
    },
    "data_buffers_bytes": {
        "tile": {"activation": 64, "partial_sums": 12, "output_data_be_tags": 12.5},
        "row": {"activation": 168, "partial_sums": 84, "output_data_be_tags": 50},
    },
    "planned_pnr_width_um": 2000,
    "planned_pnr_height_um": 2000,
    "cell_area_budget_mm2": 3,
    "corner": "TSMC180 TT",
    "effort": v["source_manifest"]["effort"],
    "synthesis_optimized_period_ns": 16,
    "report_period_ns": 20,
    "post_route_verified": False,
}
f = ROOT / "reports/cnn_row_order_validation.json"
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
