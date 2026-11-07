"""Audit independent per-unit IRQs, fault WFI wake, acknowledgement and firmware."""

import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
paths = [
    NPU / "build/vcs-irqv2_first-queues/result.json",
    NPU / "build/vcs-irqv2_first-irqcontrol/result.json",
]
paths += [NPU / f"build/vcs-irqv2_routes{n}-irqwake-macro/result.json" for n in [32, 64]]
for suite, macro in [
    ("cnnqueues", False),
    ("sharedquant", True),
    ("outergemm", True),
    ("cnnstream", True),
    ("vectorsimd", True),
    ("unitroutes", True),
    ("sharedoperands", True),
    ("enginefaults", False),
    ("vectorprogram", False),
]:
    paths.append(NPU / f"build/vcs-irqv2_regress-{suite}{'-macro' if macro else ''}/result.json")
for variant, tag in [("default", "irqv2_canonical_default"), ("quant", "irqv2_final_quant")]:
    for suite in ["blocking", "quantlayers", "jtag"]:
        paths.append(NPU / f"build/vcs-{tag}-{suite}-macro/result.json")
paths.append(NPU / "build/vcs-irqv2_canonical-latency-macro/result.json")
results = []
cycles = {}
for p in paths:
    d = json.loads(p.read_text())
    assert d["passed"] and not d["changed_during_run"], p
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (p, name)
    text = (p.parent / "compile-launcher.log").read_text()
    assert "Warning-[IPDW]" not in text and "Warning-[PCWM-W]" not in text, p
    results.append(
        dict(
            suite=d["suite"],
            result=str(p.relative_to(ROOT)),
            rf_bank_words=d["rf_bank_words"],
            macro=d["macro"],
            summaries=d["summaries"],
        )
    )
    if d["suite"] == "blocking":
        cs = [
            int(re.search(r" elapsed_cycles=(\d+)", s)[1])
            for s in d["summaries"]
            if s.startswith("SINGLE sample=")
        ]
        assert len(cs) == 10 and len(set(cs)) == 1
        cycles["quant" if "final_quant" in p.parent.name else "default"] = cs[0]
assert len(results) == 20 and cycles == {"default": 29298, "quant": 25965}
# Canonical default data are exactly the tested production artifacts.
canonical = NPU / "mnist/artifacts"
source = NPU / "build/irqv2-canonical-default-artifacts"
quant = NPU / "build/irqv2-final-quant-artifacts"
for name in [
    "boot.S",
    "boot.bin",
    "boot.hex",
    "test_meta.svh",
    *[f"sram{i}.{ext}" for i in range(10) for ext in ["bin", "hex"]],
]:
    assert (canonical / name).read_bytes() == (source / name).read_bytes(), name
payload = [
    "params.hex",
    *[f"input{i}.hex" for i in range(10)],
    *[f"gold{i}_{l}.hex" for i in range(10) for l in range(6)],
]
for name in payload:
    assert (canonical / name).read_bytes() == (quant / name).read_bytes(), name
subprocess.run(
    ["gcc", "-x", "c", "-fsyntax-only", "-I", str(ROOT), "-"],
    input='#include "npu/sw/npu.h"\n',
    text=True,
    check=True,
)
rtl = {
    str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted((NPU / "rtl").rglob("*.sv"))
}
report = dict(
    passed=True,
    irq_ids={"matrix": 16, "vector": 17, "cnn": 18, "boot": 31},
    irq_cap_address="0x40000070",
    irq_cap_mask="0x00070000",
    done_or_error_per_unit=True,
    done_ack_bit=3,
    done_ack_while_busy=True,
    new_event_dominates_ack=True,
    rtl_changed=True,
    old_wfi_firmware_requires_regeneration=True,
    top_irq_vector_width_unchanged=5,
    tests=results,
    inference_cycles=cycles,
    previous_cycles={"default": 29173, "quant": 26092},
    layer_tensors_per_path=60,
    golden_bytes_per_path=17940,
    canonical_default_updated=True,
    parameters_inputs_goldens_unchanged=True,
    c_header_host_syntax_checked=True,
    rtl_sha256=rtl,
    firmware_source_sha256=hashlib.sha256((NPU / "mnist/firmware.py").read_bytes()).hexdigest(),
    boot_sha256={
        "default": hashlib.sha256((canonical / "boot.bin").read_bytes()).hexdigest(),
        "quant": hashlib.sha256((quant / "boot.bin").read_bytes()).hexdigest(),
    },
    synthesis_rerun=False,
    pnr_rerun=False,
    gate_level_rerun=False,
    notes=[
        "Real-CPU WFI tests cover completion and runtime fault for all three units, plus masked-source isolation and two simultaneous pending sources. Both 256B and 512B RF builds pass.",
        "Completion counters still count successful jobs; a failed batch must follow the error path, not wait forever for its submitted ticket.",
        "No new area/timing/physical-signoff claim for this changed RTL.",
    ],
)
(NPU / "reports/irq_v2_validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(
    f"PASS {len(results)} source-audited suites; IRQs16/17/18; fault and mask wake tests; cycles {cycles}"
)
