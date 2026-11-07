"""Archive pure CNN arithmetic plus compact stream transfer evidence."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--baseline", type=Path, required=True)
p.add_argument("--tag", default="minimal-compute-final")
p.add_argument("--gate-tags", nargs="*", default=[])
p.add_argument("--out", type=Path, default=ROOT / "npu/reports/minimal_compute_validation.json")
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())
m = read(r / "source_manifest.json")
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (r / "launcher.log").read_text()
for name, digest in m["source_sha256"].items():
    assert sha(ROOT / name) == digest, name
for name, digest in read(r / "library_manifest.json").items():
    assert sha(name) == digest, name


def ppa(run, old=False):
    area = (run / "reports/area.rpt").read_text()
    qor = (run / "reports/qor.rpt").read_text()
    hierarchy = {}
    records = []
    stack = []
    for line in area.splitlines():
        entry = re.match(r"^(\s+)(\S+)\s+(\S+)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$", line)
        if not entry:
            continue
        depth, name, value = len(entry[1]), entry[2], float(entry[5]) / 1e6
        while stack and stack[-1][0] >= depth:
            stack.pop()
        records.append((depth, name, value))
        path = (stack[-1][1] + "_" if stack else "") + name
        hierarchy[path] = value
        stack.append((depth, path))
    cells = float(re.search(r"Cell Area\s+([\d.]+)", qor)[1]) / 1e6
    match = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
    # Both SRAM macro areas are fixed by the identical library manifest.
    macro_mm2 = 0.802887182
    if old:
        # Old Genus run flattened npu_core into the ASIC top; direct child rows
        # have exactly two leading spaces. Keep their complete instance names.
        direct = {name: value for depth, name, value in records if depth == 2}
        engine = direct["i_core_i_cnn_i_engine"]
        control = direct["i_core_i_cnn_i_control"]
        arithmetic = hierarchy["i_core_i_cnn_i_engine_i_mac"]
        local = cells - macro_mm2 - sum(direct.values())
        cnn_only = engine + control
        combined = cnn_only + local
    else:
        direct = {name: value for depth, name, value in records if depth == 4}
        engine = hierarchy["i_core_i_stream_i_engine"]
        control = hierarchy["i_core_i_stream_i_control"]
        # Genus absorbed DOT9 into npu_core. Do not invent a separate CNN area.
        # Include ALL local core/top glue along with it, in both baseline/new
        # totals, rather than incorrectly presenting stream-only area as CNN.
        local = cells - macro_mm2 - sum(direct.values())
        arithmetic = None
        cnn_only = None
        combined = engine + control + local
    return dict(
        cell_area_mm2=cells,
        xbar_mm2=hierarchy["i_core_i_xbar"],
        rf_mm2=hierarchy["i_core_i_xbar_i_regfile"],
        arithmetic_mm2=arithmetic,
        arithmetic_area_note="Included in core local logic after Genus flattening"
        if not old
        else "Nested in CNN engine",
        transfer_engine_mm2=engine,
        transfer_control_mm2=control,
        all_top_core_local_logic_mm2=local,
        cnn_only_mm2=cnn_only,
        cnn_transfer_and_all_local_glue_mm2=combined,
        sys_setup_slack_ns=float(match[1]) / 1000,
        sys_tns_ns=float(match[2]) / 1000,
        hierarchy_mm2=hierarchy,
        area_report_sha256=sha(run / "reports/area.rpt"),
        qor_report_sha256=sha(run / "reports/qor.rpt"),
    )


def archive_result(source, category, label):
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
        summaries=j.get("summaries", []),
        snapshots=snapshots,
    )


suites = [
    "cnncompute",
    "cnnqueues",
    "regfile",
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
    s: archive_result(ROOT / "npu/build" / f"vcs-{a.tag}-{s}" / "result.json", "rtl_tests", s)
    for s in suites
}
gates = {
    tag: archive_result(ROOT / "npu/build" / f"gate-{tag}" / "result.json", "gate_tests", tag)
    for tag in a.gate_tags
}
log = Path(rtl["latency"]["result"]).with_name("run.log").read_text()
cycles = [int(v) for v in re.findall(r"SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", log)]
assert len(cycles) == 10 and len(set(cycles)) == 1, cycles
stream_log = Path(rtl["stream"]["result"]).with_name("run.log").read_text()
stream_match = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", stream_log)
assert stream_match and int(stream_match[1]) == 20
model = read(ROOT / "npu/mnist/artifacts/model.json")
assert model["stream_abi"] == "SD91" and model["stream_tasks"] == 296
firmware = r / "firmware"
firmware.mkdir(exist_ok=True)
for f in (ROOT / "npu/mnist/artifacts").iterdir():
    if f.suffix in [".hex", ".bin", ".svh", ".json", ".S"]:
        shutil.copy2(f, firmware / f.name)
for name in ["firmware.py", "stream_firmware.py"]:
    shutil.copy2(ROOT / "npu/mnist" / name, firmware / name)
base = a.baseline.resolve()
assert read(r / "library_manifest.json") == read(base / "library_manifest.json")
base_manifest = read(base / "source_manifest.json")
for key in [
    "effort",
    "rf_bank_words",
    "cnn_queue_depth",
    "matrix_queue_depth",
    "vector_queue_depth",
    "synth_period_ns",
    "report_period_ns",
]:
    assert m[key] == base_manifest[key], key
unchanged = {}
# Firmware changed deliberately; parameters, input and every integer golden did not.
for f in (base / "firmware").glob("*.hex"):
    if f.name.startswith(("params", "input", "gold")):
        current = ROOT / "npu/mnist/artifacts" / f.name
        assert sha(current) == sha(f), f
        unchanged[f.name] = sha(f)
assert "params.hex" in unchanged and len(unchanged) > 10
software_check = read(r.parent / "software-checks/result.json")
assert (
    software_check["passed"] and "STREAM SOFTWARE CHECK PASS checks=628" in software_check["stdout"]
)
for name, digest in software_check["sha256"].items():
    assert sha(name) == digest, name
    shutil.copy2(name, r.parent / "software-checks" / Path(name).name)
current = ppa(r)
baseline = ppa(base, True)
old_cycles = 25156
report = dict(
    scope="Pure DOT9 CNN plus compact shared transfer shell; TSMC180 TT mapped synthesis and no-SDF simulation. No new place/route or PAD result.",
    run=str(r),
    configuration=m,
    ppa=current,
    baseline=dict(run=str(base), ppa=baseline, inference_cycles=old_cycles),
    delta=dict(
        cell_area_mm2=current["cell_area_mm2"] - baseline["cell_area_mm2"],
        cnn_transfer_and_all_local_glue_mm2=current["cnn_transfer_and_all_local_glue_mm2"]
        - baseline["cnn_transfer_and_all_local_glue_mm2"],
        inference_cycles=cycles[0] - old_cycles,
    ),
    software=dict(
        inference_cycles=cycles[0],
        input_dma_inclusive_cycles=cycles[0] + 621,
        stream_frames=int(stream_match[1]),
        stream_elapsed_cycles=int(stream_match[2]),
        stream_average_cycles=int(stream_match[2]) / int(stream_match[1]),
        cycle_target_met=cycles[0] < 20000,
        stream_tasks=296,
        matrix_fc_tasks=90,
        stream_task_bits=32,
        cnn_abi="SD91 0x53443931",
        program_image_bytes=model["firmware_bytes"],
        task_table_bytes=296 * 4,
        parameter_bytes=model["parameter_bytes"],
        shared_rf_partial_bytes=32,
    ),
    removed=[
        "private 28x24 partial array",
        "private 32x24 output FIFO",
        "hardware whole-tensor shape and overlap validation",
        "81-bit command payload",
        "associative window tags",
        "per-job profiling counters",
    ],
    software_checks=software_check,
    rtl=rtl,
    gates=gates,
    changed_rtl_sources=[
        k for k, v in m["source_sha256"].items() if base_manifest["source_sha256"].get(k) != v
    ],
    removed_rtl_sources=sorted(set(base_manifest["source_sha256"]) - set(m["source_sha256"])),
    unchanged_parameters_input_golden_sha256=unchanged,
    firmware_sha256={f.name: sha(f) for f in firmware.iterdir() if f.is_file()},
    area_budget_met=current["cell_area_mm2"] <= 3.0,
    limitations=[
        "Inference is slower than baseline and exceeds the original 20k target.",
        "Area includes two SRAM macros, excludes PAD and implementation cells; synthesis timing is not routed timing.",
        "Transfer shell still sequences addresses/channels. Arithmetic has no task FIFO or tensor FSM.",
        "Software must validate full tensors, borders, ranges and ownership; low-level MMIO does not prove those properties.",
        "Matrix and Vector internals are unchanged by this CNN refactor.",
    ],
)
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: report[k] for k in ["ppa", "delta", "software"]}, indent=2))
