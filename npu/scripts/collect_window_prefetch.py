"""Archive circular-window/RF-prefetch regressions, ablation and measured cycles."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, default=ROOT.parent / "eda-runs/20261105-window-prefetch")
p.add_argument("--tag", default="window-prefetch-final")
p.add_argument("--out", type=Path, default=ROOT / "npu/reports/window_prefetch_validation.json")
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())


def archive(source, category, label):
    j = read(source)
    assert j["passed"] and not j["changed_during_run"], source
    snapshots = {}
    for name, digest in j["sha256"].items():
        f = Path(name)
        assert sha(f) == digest, name
        if f.is_relative_to(ROOT) or f.is_relative_to(r):
            dst = r / "functional_inputs" / digest / f.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copy2(f, dst)
            assert sha(dst) == digest
            snapshots[name] = str(dst)
    dst = r / category / label
    dst.mkdir(parents=True, exist_ok=True)
    for name in ["result.json", "run.log", "command.json"]:
        if (source.parent / name).exists():
            shutil.copy2(source.parent / name, dst / name)
    return dict(
        passed=True,
        result=str(dst / "result.json"),
        result_sha256=sha(dst / "result.json"),
        run_log_sha256=sha(dst / "run.log"),
        summaries=j["summaries"],
        snapshots=snapshots,
    )


def profiles(result):
    log = Path(result["result"]).with_name("run.log").read_text()
    rows = [
        dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", line))
        for line in log.splitlines()
        if line.startswith("STAGE_PROFILE")
    ]
    assert len(rows) == 70
    for sample in range(10):
        group = rows[sample * 7 : sample * 7 + 7]
        assert [x["stage"] for x in group] == list(range(7))
        for row in group:
            assert row["cnn_busy"] == sum(
                row[k]
                for k in [
                    "cnn_issue",
                    "cnn_weight",
                    "cnn_output",
                    "cnn_seed",
                    "cnn_input",
                    "cnn_other",
                ]
            )
    elapsed = [int(v) for v in re.findall(r"SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", log)]
    assert len(elapsed) == 10 and len(set(elapsed)) == 1
    assert all(sum(x["cycles"] for x in rows[i * 7 : i * 7 + 7]) == elapsed[i] for i in range(10))
    return rows, elapsed[0]


suites = [
    "rfsink",
    "purecompute",
    "cnncompute",
    "regfile",
    "cnnqueues",
    "ops",
    "jtag",
    "soc",
    "xbar",
    "xbarconcurrent",
    "dma",
    "queues",
    "burst",
    "enginefaults",
    "vectorprogram",
    "latency",
    "layers",
    "stream",
]
rtl = {
    s: archive(ROOT / "npu/build" / f"vcs-{a.tag}-{s}" / "result.json", "rtl_tests", s)
    for s in suites
}
macro = archive(
    ROOT / "npu/build" / f"vcs-{a.tag}-latency-macro" / "result.json", "rtl_tests", "latency-macro"
)
no_cache = archive(
    ROOT / "npu/build/vcs-window-prefetch-no-cache-latency/result.json",
    "ablations",
    "no-rf-weight-cache",
)
rows, cycles = profiles(rtl["latency"])
macro_rows, macro_cycles = profiles(macro)
assert rows == macro_rows and macro_cycles == cycles
ablation_rows, ablation_cycles = profiles(no_cache)
base_file = ROOT / "npu/reports/pure_compute_validation.json"
baseline = read(base_file)
base_cycles = baseline["software"]["inference_cycles"]
assert cycles == 25388 and cycles < base_cycles
assert cycles < ablation_cycles
sample = rows[:7]
totals = {k: sum(x[k] for x in sample) for k in sample[0] if k not in ["sample", "stage"]}
assert totals["rf_sink_words"] == totals["cnn_seed_read_words"] == 3472
assert totals["cnn_weight_gather_words"] == 840 and totals["cnn_weight_words"] == 2400
assert totals["cnn_activation_words"] == 6128 and totals["cnn_activation_gather_words"] == 1344
assert totals["rf_sink_sram_overlap"] > 0 and totals["rf_sink_gather_overlap"] > 0
assert totals["cnn_input"] < baseline["totals"]["cnn_input"]
log = Path(rtl["stream"]["result"]).with_name("run.log").read_text()
stream = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", log)
assert stream and int(stream[1]) == 20
model = read(ROOT / "npu/mnist/artifacts/model.json")
assert model["rf_weight_stage_bytes"] == [20, 72, 0, 0, 0, 0]
unchanged = {}
for f in (r / "before/artifacts").glob("*"):
    if f.name.startswith(("params", "input", "gold")) and f.suffix in [".bin", ".hex"]:
        assert sha(ROOT / "npu/mnist/artifacts" / f.name) == sha(f), f
        unchanged[f.name] = sha(f)
assert len(unchanged) > 60
pure = {}
for name in ["npu_cnn.sv", "npu_cnn_mac.sv", "npu_matmul.sv", "npu_vector.sv"]:
    f = ROOT / "npu/rtl" / name
    assert sha(f) == sha(r / "before/rtl" / name), name
    pure[name] = sha(f)
firmware = r / "firmware"
firmware.mkdir(exist_ok=True)
for f in (ROOT / "npu/mnist/artifacts").iterdir():
    if f.suffix in [".hex", ".bin", ".svh", ".json", ".S"]:
        shutil.copy2(f, firmware / f.name)
for name in ["firmware.py", "stream_firmware.py"]:
    shutil.copy2(ROOT / "npu/mnist" / name, firmware / name)
report = dict(
    scope="Three-word circular CNN window, response forwarding, RF weight gather and RF-only result sink; functional RTL/macro tests and cycle measurements. No new synthesis or PnR.",
    run=str(r),
    configuration=read(ROOT / "npu/build_config.json"),
    baseline=dict(
        report=str(base_file),
        sha256=sha(base_file),
        software=baseline["software"],
        totals=baseline["totals"],
        stage_profiles=baseline["stage_profiles"],
    ),
    software=dict(
        inference_cycles=cycles,
        input_dma_inclusive_cycles=cycles + 621,
        input_dma_cycles=621,
        delta_cycles=cycles - base_cycles,
        cycle_reduction_percent=(base_cycles - cycles) * 100 / base_cycles,
        throughput_speedup_percent=(base_cycles / cycles - 1) * 100,
        cycle_target_met=cycles < 20000,
        stream_frames=20,
        stream_elapsed_cycles=int(stream[2]),
        stream_average_cycles=int(stream[2]) / 20,
        rf_weight_stage_bytes=model["rf_weight_stage_bytes"],
        rf_copy_bytes_per_image=92,
        program_image_bytes=model["firmware_bytes"],
        cnn_tasks=296,
        matrix_tasks=90,
    ),
    hardware=dict(
        window_words_per_row=3,
        window_payload_bytes=36,
        old_window_payload_bytes=24,
        rf_bytes=256,
        rf_physical_banks=8,
        rf_gather_read_lanes=3,
        ordinary_xbar_masters=8,
        rf_internal_legacy_requesters=9,
        rf_physical_bank_ports_unchanged=True,
        rf_sink=True,
        compute_unit_sha256=pure,
        compute_units_unchanged=True,
    ),
    stage_profiles=sample,
    all_profiles=rows,
    totals=totals,
    delta_totals={k: totals[k] - baseline["totals"][k] for k in baseline["totals"] if k in totals},
    ablation=dict(
        no_rf_weight_cache=no_cache,
        inference_cycles=ablation_cycles,
        cached_minus_uncached_cycles=cycles - ablation_cycles,
        stage_profiles=ablation_rows[:7],
        note="Same current RTL with frozen pre-cache SD91 firmware. Software changes only add two RF weight-copy loops; original integer parameters/golden unchanged.",
    ),
    rtl=rtl,
    sram_macro_latency=macro,
    unchanged_parameters_inputs_golden_sha256=unchanged,
    firmware_sha256={f.name: sha(f) for f in firmware.iterdir() if f.is_file()},
    physical_result=dict(
        measured_for_current_revision=False,
        historical_report="npu/reports/minimal_compute_validation.json",
    ),
    limitations=[
        "The <20k cycle target remains unmet.",
        "The ring adds 12B of operand staging, not shared RF capacity; current area/timing require new synthesis and physical verification.",
        "RF weight staging is enabled only when both live tensors are in SRAM and the padded complete weight block fits below the 32B partial workspace.",
        "RF store and gather still arbitrate single-port physical banks; dedicated sink does not guarantee same-bank parallel access.",
        "Exclusive CNN reason bins have priority and may move cycles between causes as one bottleneck is removed.",
    ],
)
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
shutil.copy2(__file__, r / "collect_window_prefetch.py")
print(
    json.dumps(
        dict(
            software=report["software"],
            totals=totals,
            ablation_cycles=ablation_cycles,
            rtl_suites=len(rtl),
        ),
        indent=2,
    )
)
