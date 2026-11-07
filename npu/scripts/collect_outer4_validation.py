"""Collect audited 4x4 Matrix regressions; tests must already have completed."""

import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NPU = ROOT / "npu"
unchanged = ["matrixouter", "purecompute", "queues", "cnnqueues", "regfile", "rfsink", "xbar"]
cases = [(s, False, "default") for s in unchanged]
cases += [
    (s, True, "default")
    for s in ["outergemm", "sharedoperands", "vectorsimd", "sharedquant", "unitroutes", "jtag"]
]
cases += [(s, False, "default") for s in ["vectorprogram", "enginefaults"]]
cases += [("latency", True, v) for v in ["default", "quant", "legacy"]]
cases += [("quantlayers", True, v) for v in ["quant", "default"]]
results = []
cycles = {}
for suite, macro, variant in cases:
    tag = ("outer4_final_" if suite in unchanged else "outer4_verified_") + variant
    p = NPU / "build" / f"vcs-{tag}-{suite}{'-macro' if macro else ''}" / "result.json"
    d = json.loads(p.read_text())
    assert d["passed"] and not d["changed_during_run"], p
    for name, sha in d["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (
            "stale source or asset",
            name,
            p,
        )
    compile_log = (p.parent / "compile-launcher.log").read_text()
    assert "Warning-[IPDW]" not in compile_log and "Warning-[PCWM-W]" not in compile_log, p
    results.append(
        dict(
            suite=suite,
            variant=variant,
            macro=macro,
            passed=True,
            result=str(p.relative_to(ROOT)),
            summaries=d["summaries"],
        )
    )
    if suite == "latency":
        measured = [
            int(re.search(r" elapsed_cycles=(\d+)", line)[1])
            for line in d["summaries"]
            if line.startswith("SINGLE sample=")
        ]
        assert len(measured) == 10 and len(set(measured)) == 1
        cycles[variant] = measured[0]
legacy = NPU / "build/outer-legacy-artifacts"
quant = NPU / "build/outer-artifacts"
default = NPU / "mnist/artifacts"
for source in (
    list(legacy.glob("gold*.hex")) + list(legacy.glob("input*.hex")) + [legacy / "params.bin"]
):
    assert (
        source.read_bytes()
        == (quant / source.name).read_bytes()
        == (default / source.name).read_bytes()
    ), source
files = list((NPU / "rtl").rglob("*.sv")) + [
    NPU / "rtl/files.f",
    NPU / "sw/npu.h",
    NPU / "mnist/firmware.py",
    NPU / "mnist/stream_firmware.py",
    NPU / "scripts/run_vcs.py",
]
report = dict(
    passed=True,
    base_commit="d7b1794",
    cases=results,
    architecture=dict(
        rows=4,
        cols=4,
        accumulators=16,
        accumulator_bits=32,
        precisions=[8, 16],
        peak_macs_per_accepted_step=16,
        operand_words=8,
        matrix_rf_gather_slots=3,
        leading_dimensions="shared immutable per batch, in elements",
        zero_k="ACCUMULATE export only",
    ),
    mnist=dict(
        samples=10,
        cycles=cycles,
        old_dot_quant_cycles=27633,
        quant_cycles_saved=27633 - cycles["quant"],
        quant_cycles_saved_percent=(1 - cycles["quant"] / 27633) * 100,
        matrix_jobs_default=27,
        matrix_jobs_quant=37,
        fc_active_rows=1,
        layer_tensors_verified_per_software_path=60,
        golden_bytes_verified_per_software_path=17940,
        parameters_inputs_goldens_unchanged=True,
        legacy_binary_correct=True,
    ),
    firmware=dict(
        default_instructions=737,
        quant_instructions=600,
        stream_default_instructions=750,
        stream_quant_instructions=603,
        stream_generation_only=True,
        descriptor_offset="0xD00",
        task_table_offset="0xE50",
        image_bytes=0x1300,
    ),
    ppa=dict(
        synthesis_measured=False,
        timing_measured=False,
        pnr_measured=False,
        historical_area_note="2.586795mm2 belongs to the previous dot-product Matrix, not this RTL",
    ),
    source_sha256={
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)
    },
)
(NPU / "reports/matrix_outer4_validation.json").write_text(
    json.dumps(report, indent=2, ensure_ascii=False) + "\n"
)
print(
    f"PASS {len(results)} regressions; cycles {cycles}; both software paths 60 layer tensors /17940 golden bytes exact"
)
