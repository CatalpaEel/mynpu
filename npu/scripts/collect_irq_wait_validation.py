"""Audit IRQ/WFI firmware against the identical polling binary and fixed RTL."""

import collections
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
area = json.loads((NPU / "reports/area25_area_validation.json").read_text())


def verify(path):
    d = json.loads(path.read_text())
    assert d["passed"] and not d.get("changed_during_run", []), path
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (path, name)
        f = Path(name)
        if f.is_relative_to(ROOT) and str(f.relative_to(ROOT)).startswith("npu/rtl/"):
            assert sha == area["source_sha256"][str(f.relative_to(ROOT))]
    if (path.parent / "compile-launcher.log").exists():
        log = (path.parent / "compile-launcher.log").read_text()
        assert "Warning-[IPDW]" not in log and "Warning-[PCWM-W]" not in log
    return d


variants = {}
for variant, tag, artifact, cycles in [
    ("poll", "irq_first_poll", "irq-poll-artifacts", 27432),
    ("irq", "irq_final", "irq-artifacts", 26092),
    ("queue_irq", "irq_full", "irq-full-artifacts", 26150),
]:
    path = NPU / "build" / f"vcs-{tag}-blocking-macro/result.json"
    d = verify(path)
    text = (path.parent / "run.log").read_text()
    totals = {}
    stages = {}
    for prefix in [
        "STAGE_PROFILE",
        "CPU_BLOCK_PROFILE",
        "CPU_SOFTWARE_PROFILE",
        "BUS_BLOCK_PROFILE",
    ]:
        values = {}
        for line in text.splitlines():
            if line.startswith(prefix + " "):
                v = {k: int(n) for k, n in re.findall(r"(\w+)=(\d+)", line)}
                sample = v.pop("sample")
                stage = v.pop("stage")
                assert (sample, stage) not in values
                values[sample, stage] = v
        assert len(values) == 70
        counts = []
        for sample in range(10):
            c = collections.Counter()
            for stage in range(7):
                c.update(values[sample, stage])
            if prefix == "CPU_BLOCK_PROFILE":
                assert c["cycles"] == cycles == sum(n for k, n in c.items() if k != "cycles")
            if prefix == "CPU_SOFTWARE_PROFILE":
                assert sum(c.values()) == cycles
            if prefix == "STAGE_PROFILE":
                assert c["cycles"] == cycles
            counts.append(dict(c))
        totals[prefix] = {k: sum(c[k] for c in counts) / 10 for k in counts[0]}
        stages[prefix] = [
            {k: sum(values[s, l][k] for s in range(10)) / 10 for k in counts[0]} for l in range(7)
        ]
    assert text.count("BLOCKING PASS sample=") == 10
    variants[variant] = dict(
        result=str(path.relative_to(ROOT)),
        cycles=cycles,
        profiles=totals,
        stages=stages,
        artifact_dir=f"npu/build/{artifact}",
        boot_sha256=hashlib.sha256(
            (NPU / "build" / artifact / "boot.bin").read_bytes()
        ).hexdigest(),
        summaries=d["summaries"],
    )
# All model bytes and goldens must be identical across variants.
files = [
    "params.hex",
    *[f"input{i}.hex" for i in range(10)],
    *[f"gold{i}_{j}.hex" for i in range(10) for j in range(6)],
]
shared = {}
for name in files:
    hashes = [
        hashlib.sha256((ROOT / v["artifact_dir"] / name).read_bytes()).hexdigest()
        for v in variants.values()
    ]
    assert len(set(hashes)) == 1, name
    shared[name] = hashes[0]
assert (NPU / "build/irq-poll-artifacts/boot.bin").read_bytes() == (
    NPU / "build/outer-artifacts/boot.bin"
).read_bytes()
additional = []
for suite in ["quantlayers", "jtag"]:
    path = NPU / "build" / f"vcs-irq_final-{suite}-macro/result.json"
    d = verify(path)
    additional.append(
        dict(suite=suite, result=str(path.relative_to(ROOT)), summaries=d["summaries"])
    )
gate = ROOT.parent / "eda-runs/20261107-area25-profile-hier/gls-latency-irq-final/result.json"
d = verify(gate)
assert any("input_to_classification_cycles=26484 " in line for line in d["summaries"])
additional.append(dict(suite="gate_latency", result=str(gate), summaries=d["summaries"]))
compat = json.loads((NPU / "build/irq-default-compat.json").read_text())
assert compat["passed"]
for name, sha in compat["files"].items():
    assert hashlib.sha256((NPU / "mnist/artifacts" / name).read_bytes()).hexdigest() == sha
reproduction = json.loads((NPU / "build/irq-reproduction.json").read_text())
assert reproduction["passed"]
for name, sha in reproduction["boot_sha256"].items():
    assert variants[name]["boot_sha256"] == sha
source = NPU / "mnist/firmware.py"
r = dict(
    passed=True,
    selected="irq",
    variants=variants,
    additional=additional,
    rtl_changed=False,
    rtl_matches_measured_18ns_gated_design=True,
    firmware_source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    shared_model_assets_sha256=shared,
    default_vector_binary_unchanged=compat,
    cycle_saved=27432 - 26092,
    cycle_saved_percent=(1 - 26092 / 27432) * 100,
    irq_mode="mie[16]=1; mstatus.MIE=0; level interrupt wakes WFI, no trap handler",
    matrix_limit="Matrix sticky done can only be acknowledged idle: one IRQ wake followed by tail polling when needed",
    counter_note="completion_poll is active PC occupancy of the wait loop, including IRQ acknowledge/recheck; it no longer means continuous busy polling",
    synthesis_rerun=False,
    current_generator_reproduces_measured_binaries=reproduction,
)
(NPU / "reports/irq_wait_validation.json").write_text(json.dumps(r, indent=2) + "\n")
print(
    "PASS: three 10-image profiles, identical model bytes, 60 layer tensors, JTAG, exact 18ns gate netlist, unchanged generic Vector binary"
)
print("Cycles: 27432 -> 26092 (-4.88%); optional queue IRQ 26150")
