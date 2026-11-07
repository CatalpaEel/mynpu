"""Collect and freeze evidence for generic xbar stream routing."""

import hashlib
import json
import shutil
from rtl_sources import resolve_recorded_source
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT.parent / "eda-runs/20261105-xbar-stream-routes"
RUN.mkdir(parents=True, exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
tests = {}
paths = {}
for suite in [
    "unitroutes",
    "unitroutes_macro",
    "xbarstream",
    "xbar",
    "xbarconcurrent",
    "rfsink",
    "vectorprogram",
    "enginefaults",
    "cnnqueues",
    "queues",
    "regfile",
    "purecompute",
    "latency",
    "jtag",
]:
    suffix = "-macro" if suite in ["latency", "jtag", "unitroutes_macro"] else ""
    tag_suite = "unitroutes" if suite == "unitroutes_macro" else suite
    tag = (
        "xbar_routes_checked"
        if suite in ["unitroutes", "unitroutes_macro", "jtag", "latency", "cnnqueues"]
        else "xbar_routes_final"
    )
    directory = ROOT / f"npu/build/vcs-{tag}-{tag_suite}{suffix}"
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
    for name in ["result.json", "run.log", "compile.log", "command.json", "npu_soc_macro.sv"]:
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
    scope="Generic xbar FIFO endpoints and independent compute masters; no new synthesis/PNR results",
    no_dedicated_cnn_vector_ports=True,
    data_path="Any compute result -> ordinary xbar write -> addressed FIFO -> ordinary xbar read -> any compute operand",
    ordinary_masters=6,
    rf_internal_masters=7,
    shared_rf_bytes=256,
    stream_channels=4,
    stream_depth_words=16,
    stream_word_bits=32,
    stream_base="0x80006000",
    stream_channel_stride_bytes=256,
    stream_payload_bytes=256,
    software_schedule="Consumers first; concurrent producers and consumers; software owns routing, word counts and deadlock avoidance",
    inference_cycles=25877,
    previous_rf_serial_cycles=48897,
    previous_direct_stream_cycles=25388,
    increase_vs_direct_percent=(25877 / 25388 - 1) * 100,
    decrease_vs_rf_serial_percent=(1 - 25877 / 48897) * 100,
    firmware_instructions=712,
    tests=tests,
    unchanged_model_inputs_and_golden=unchanged,
    frozen_inputs={str(p.relative_to(ROOT)): digest for p, digest in paths.items()},
    archive=str(RUN),
    limitations=[
        "FIFO endpoints consume ordered words; no automatic tensor replay, broadcast or precision conversion",
        "Empty reads and full writes stall; software must avoid cyclic waits and unmatched counts",
        "Reset is required to discard residual words after an aborted dataflow",
        "JTAG/SBA bus-error feedback remains limited by the existing DM",
        "Historical PPA is not a measurement of this implementation",
    ],
)
out = ROOT / "npu/reports/xbar_stream_routes_validation.json"
out.write_text(json.dumps(report, indent=2) + "\n")
shutil.copy2(out, RUN / "validation.json")
print(
    json.dumps(dict(passed_suites=len(tests), inference_cycles=25877, archive=str(RUN)), indent=2)
)
