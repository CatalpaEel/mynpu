"""Audit VPG1 software, RTL regressions, mapped PPA and gate evidence separately."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--out", type=Path, default=ROOT / "npu/reports/vector_program_validation.json")
p.add_argument("--allow-pending", action="store_true")
p.add_argument("--gate-tags", nargs="*", default=[])
p.add_argument("--default-smoke-tag")
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())
suites = [
    "latency",
    "layers",
    "stream",
    "soc",
    "jtag",
    "ops",
    "burst",
    "xbar",
    "xbarconcurrent",
    "queues",
    "cnnqueues",
    "dma",
    "enginefaults",
    "regfile",
    "vectorprogram",
]
macro_suites = set(suites[:7])
assert not (ROOT / "npu/rtl/npu_vector_post.sv").exists()
old_run = r.parent / "20261103-logic-trim/asic"
old = read(old_run / "source_manifest.json")


def qor(directory):
    if (
        not (directory / "reports/qor.rpt").exists()
        or "DUAL_BANK_ASIC_SYNTH_PASS" not in (directory / "launcher.log").read_text()
    ):
        assert a.allow_pending, directory
        return {"status": "pending"}
    q = (directory / "reports/qor.rpt").read_text()
    clocks = {}
    for clock in ["sys_clk", "jtag_clk"]:
        match = re.search(r"^" + clock + r"\s+([\d.-]+)\s+([\d.-]+)\s+(\d+)\s*$", q, re.M)
        assert match, clock
        clocks[clock] = {
            "setup_slack_ns": float(match[1]) / 1000,
            "tns_ns": float(match[2]) / 1000,
            "violating_paths": int(match[3]),
        }
    return {
        "status": "completed",
        "cell_area_mm2": float(re.search(r"^Cell Area\s+([\d.]+)", q, re.M)[1]) / 1e6,
        "clocks": clocks,
        "sha256": {
            str(f): sha(f)
            for f in [
                directory / "reports/qor.rpt",
                directory / "reports/area.rpt",
                directory / "reports/timing.rpt",
                directory / "optimized.v",
                directory / "launcher.log",
            ]
        },
    }


def freeze_test(directory, source, category="functional", label=None):
    j = read(source)
    assert j["passed"] and not j["changed_during_run"], source
    snapshots = {}
    for name, digest in j["sha256"].items():
        f = Path(name)
        # Historical RF variants can use archived images after the default
        # allocation changes; their frozen test result still identifies them.
        if f.is_relative_to(ROOT) or f.is_relative_to(r):
            dest = directory / "functional_inputs" / digest / f.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists():
                assert sha(f) == digest, name
                shutil.copy2(f, dest)
            assert sha(dest) == digest
            snapshots[name] = str(dest)
        else:
            assert sha(f) == digest, name
    target = directory / category / (label or j["suite"])
    target.mkdir(parents=True, exist_ok=True)
    for name in ["result.json", "run.log", "command.json"]:
        shutil.copy2(source.parent / name, target / name)
    return {
        "passed": True,
        "result": str(target / "result.json"),
        "result_sha256": sha(target / "result.json"),
        "run_log_sha256": sha(target / "run.log"),
        "summaries": j["summaries"],
        "snapshots": snapshots,
    }


variants = {}
for words, name, tag in [
    (64, "rf64-final", "vector-program-production"),
    (32, "rf32-final", "vector-program-rf32-production"),
]:
    directory = r / name
    manifest = read(directory / "source_manifest.json")
    for filename, digest in manifest["source_sha256"].items():
        assert sha(ROOT / filename) == digest, filename
    assert manifest["rf_bank_words"] == words
    for field in [
        "effort",
        "synth_period_ns",
        "report_period_ns",
        "matrix_queue_depth",
        "vector_queue_depth",
        "cnn_queue_depth",
    ]:
        assert manifest[field] == old[field], field
    libraries = read(directory / "library_manifest.json")
    assert libraries == read(old_run / "library_manifest.json")
    for filename, digest in libraries.items():
        assert sha(filename) == digest, filename
    changed = {
        f for f, digest in manifest["source_sha256"].items() if digest != old["source_sha256"][f]
    }
    assert changed == {"npu/rtl/npu_vector.sv", "npu/rtl/npu_mmio.sv", "npu/rtl/npu_core.sv"}, (
        changed
    )
    assert set(old["source_sha256"]) - set(manifest["source_sha256"]) == {
        "npu/rtl/npu_vector_post.sv"
    }
    functional = {}
    for suite in suites:
        suite_tag = (
            tag.replace("production", "release")
            if suite in {"latency", "layers", "stream", "jtag"}
            else tag
        )
        source = (
            ROOT
            / "npu/build"
            / ("vcs-" + suite_tag + "-" + suite + ("-macro" if suite in macro_suites else ""))
            / "result.json"
        )
        if not source.exists():
            assert a.allow_pending, source
            continue
        functional[suite] = freeze_test(directory, source)
    latency = functional.get("latency", {}).get("summaries", [])
    single = re.findall(r"SINGLE sample=(\d+).*?elapsed_cycles=(\d+)", "\n".join(latency))
    total = re.findall(
        r"SINGLE_INPUT sample=(\d+).*?input_to_classification_cycles=(\d+)", "\n".join(latency)
    )
    if not a.allow_pending:
        assert len(functional) == 15 and len(single) == len(total) == 10
    variants[str(words * 8) + "B"] = {
        "configuration": {
            field: manifest[field]
            for field in [
                "rf_bank_words",
                "matrix_queue_depth",
                "vector_queue_depth",
                "cnn_queue_depth",
            ]
        },
        "functional": functional,
        "synthesis": qor(directory),
        "inference_cycles": sorted({int(v) for _, v in single}),
        "input_dma_plus_inference_cycles": sorted({int(v) for _, v in total}),
        "source_manifest_sha256": sha(directory / "source_manifest.json"),
    }

gates = {}
for tag in a.gate_tags:
    source = ROOT / "npu/build" / ("gate-" + tag) / "result.json"
    directory = r / ("rf32-final" if "-32-" in tag else "rf64-final")
    archived = freeze_test(directory, source, "gate", tag)
    gates[tag] = {**archived, "sdf": read(source)["sdf"]}

default_smoke = None
if a.default_smoke_tag:
    source = ROOT / "npu/build" / ("vcs-" + a.default_smoke_tag + "-latency-macro") / "result.json"
    j = read(source)
    assert j["rf_bank_words"] == read(ROOT / "npu/build_config.json")["rf_bank_words"]
    assert j["max_cycles"] == 20000
    default_smoke = freeze_test(r / "rf32-final", source, "default", a.default_smoke_tag)
report = {
    "scope": "VPG1 generic vector instructions replace the retired private quantization engine. TT pre-route synthesis includes CPU/JTAG, all compute, DMA, two SRAM macros, shared RF; excludes PAD. No new PnR result.",
    "default_configuration_sha256": sha(ROOT / "npu/build_config.json"),
    "default_smoke": default_smoke,
    "default_rf_bytes": read(ROOT / "npu/build_config.json")["rf_bank_words"] * 8,
    "baseline_rf512_synthesis": qor(old_run),
    "baseline_rf256_synthesis": qor(old_run.parent / "rf32"),
    "variants": variants,
    "gate_tests": gates,
    "software_sha256": {
        str(ROOT / f): sha(ROOT / f)
        for f in ["npu/mnist/firmware.py", "npu/mnist/stream_firmware.py", "npu/sw/npu.h"]
    },
    "abi": {
        "address": "0x40000058",
        "value": "0x56504731",
        "program_words": 16,
        "temporary_registers": "4 x signed64",
        "fused_requant_supported": False,
    },
    "limitations": [
        "TT synthesis and zero-delay gate simulation are distinct from routed timing or foundry signoff.",
        "JTAG loading time is excluded from inference and simulated RX DMA figures.",
        "Program instructions are immutable while any vector work is queued or active.",
    ],
}
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
print(
    json.dumps(
        {
            name: {
                "inference_cycles": row["inference_cycles"],
                "input_plus_inference": row["input_dma_plus_inference_cycles"],
                "synthesis": row["synthesis"],
            }
            for name, row in variants.items()
        },
        indent=2,
    )
)
