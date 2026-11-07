"""Collect and freeze evidence for the memory-only CNN/Vector handoff."""

import hashlib
import json
import shutil
from rtl_sources import resolve_recorded_source
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT.parent / "eda-runs/20261105-unified-xbar"
RUN.mkdir(parents=True, exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
tests = {}
paths = {}
for suite in [
    "xbar",
    "xbarconcurrent",
    "rfsink",
    "vectorprogram",
    "enginefaults",
    "cnnqueues",
    "queues",
    "purecompute",
    "latency",
    "jtag",
]:
    suffix = "-macro" if suite in ["latency", "jtag"] else ""
    directory = ROOT / f"npu/build/vcs-unified_xbar_final-{suite}{suffix}"
    result = directory / "result.json"
    j = json.loads(result.read_text())
    assert j["passed"] and not j["changed_during_run"], suite
    for name, digest in j["sha256"].items():
        p = resolve_recorded_source(ROOT, name)
        assert sha(p) == digest, name
        if p.is_relative_to(ROOT) and not p.is_relative_to(ROOT / "npu/build"):
            paths[p] = digest
    tests[suite] = dict(result=str(result), sha256=sha(result), summaries=j["summaries"])
    out = RUN / "tests" / suite
    out.mkdir(parents=True, exist_ok=True)
    for name in ["result.json", "run.log", "compile.log", "command.json"]:
        p = directory / name
        if p.is_file():
            shutil.copy2(p, out / name)
for p, digest in paths.items():
    target = RUN / "inputs" / p.relative_to(ROOT)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, target)
    assert sha(target) == digest
baseline = ROOT.parent / "eda-runs/20261105-window-prefetch-backend/firmware"
unchanged = {}
for p in [*baseline.glob("gold*.hex"), *baseline.glob("input*.hex"), baseline / "params.hex"]:
    current = ROOT / "npu/mnist/artifacts" / p.name
    assert sha(p) == sha(current), p.name
    unchanged[p.name] = sha(p)
report = dict(
    scope="xbar rename and memory-only CNN/Vector handoff; no new synthesis/PNR results",
    data_path="CNN -> xbar RF sink -> shared RF -> xbar master2 -> Vector",
    no_dedicated_cnn_vector_ports=True,
    ordinary_masters=5,
    shared_rf_bytes=256,
    handoff_words=8,
    software_schedule="serialize each tile: CNN write drain, Vector read/compute/write drain, scratch reuse",
    inference_cycles=48897,
    previous_direct_stream_cycles=25388,
    cycle_increase_percent=(48897 / 25388 - 1) * 100,
    firmware_instructions=546,
    tests=tests,
    unchanged_model_inputs_and_golden=unchanged,
    frozen_inputs={str(p.relative_to(ROOT)): digest for p, digest in paths.items()},
    archive=str(RUN),
)
out = ROOT / "npu/reports/unified_xbar_validation.json"
out.write_text(json.dumps(report, indent=2) + "\n")
shutil.copy2(out, RUN / "validation.json")
print(
    json.dumps(dict(passed_suites=len(tests), inference_cycles=48897, archive=str(RUN)), indent=2)
)
