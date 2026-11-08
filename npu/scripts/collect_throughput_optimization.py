"""Audit five throughput/area optimizations, source hashes and optional final PPA."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NPU = Path(__file__).resolve().parents[1]
ROOT = NPU.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path)
p.add_argument("--baseline-run", type=Path)
a = p.parse_args()
SUITES = [
    ("blocking", True),
    ("quantlayers", True),
    ("jtag", True),
    ("purecompute", False),
    ("sharedquant", True),
    ("quantsync", False),
    ("readbatch", False),
    ("storepack", False),
    ("softcfg", True),
    ("vectorprogram", False),
    ("cnnstream", True),
    ("unitroutes", True),
    ("sharedoperands", True),
    ("matrixtiles", True),
    ("queues", False),
    ("irqcontrol", False),
    ("irqwake", True),
    ("enginefaults", False),
    ("cnnqueues", False),
    ("xbarstream", False),
    ("rfsink", False),
    ("regfile", False),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit_result(path):
    record = json.loads(path.read_text())
    assert record["passed"] and not record["changed_during_run"], path
    for filename, expected in record["sha256"].items():
        assert sha(Path(filename)) == expected, (path, filename)
    assert not re.search(
        r"(?:Error-|Warning-\[(?:IPDW|PCWM|SIOB))", (path.parent / "compile.log").read_text()
    ), path
    return dict(
        result=str(path.relative_to(NPU)),
        summaries=record["summaries"],
        stream_fifo_depth=record.get("stream_fifo_depth"),
    )


results = [
    dict(
        suite=suite,
        **audit_result(
            NPU / f"build/vcs-opt_final_v3-{suite}{'-macro' if macro else ''}/result.json"
        ),
    )
    for suite, macro in SUITES
]
extras = [
    audit_result(NPU / f"build/{name}/result.json")
    for name in [
        "vcs-opt_generic_vector_v3-quantlayers-macro",
        "vcs-opt_units_v3-unitsmoke",
        "vcs-opt_queueirq_v3-blocking-macro",
        "vcs-opt_fifo4_routes_v3-unitroutes-macro",
    ]
]
log = (NPU / "build/vcs-opt_final_v3-blocking-macro/run.log").read_text()
cycles = [int(v) for v in re.findall(r"^SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", log, re.M)]
assert cycles == [20728] * 10, cycles
profile = {}
for kind in ["STAGE_PROFILE", "CPU_BLOCK_PROFILE", "CPU_SOFTWARE_PROFILE", "BUS_BLOCK_PROFILE"]:
    rows = [
        dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", line))
        for line in log.splitlines()
        if line.startswith(kind + " sample=0 ")
    ]
    assert len(rows) == 7
    profile[kind] = dict(
        stages=rows,
        total={
            k: sum(row.get(k, 0) for row in rows) for k in rows[0] if k not in ["stage", "sample"]
        },
    )
canonical = NPU / "mnist/artifacts"
model = json.loads((canonical / "model.json").read_text())
assert model["shared_quant"] and model["matrix_tasks"] == 13
for path in [canonical / "params.hex", *canonical.glob("gold*_*.hex")]:
    previous = subprocess.check_output(
        ["git", "show", "6697d58:" + str(path.relative_to(ROOT))], cwd=ROOT
    )
    assert path.read_bytes() == previous, path
with tempfile.TemporaryDirectory(prefix="mynpu-throughput-") as directory:
    generated = Path(directory) / "artifacts"
    shutil.copytree(canonical, generated)
    env = os.environ.copy()
    for key in [
        "NPU_SHARED_QUANT",
        "NPU_QUANT_IRQ_WAIT",
        "NPU_QUANT_QUEUE_IRQ_WAIT",
        "NPU_RF_BANK_WORDS",
        "NPU_RF_WEIGHT_CACHE",
    ]:
        env.pop(key, None)
    env["NPU_ARTIFACTS_DIR"] = str(generated)
    subprocess.run(
        ["python3.12", str(NPU / "mnist/firmware.py")], env=env, capture_output=True, check=True
    )
    for name in [
        "boot.S",
        "boot.bin",
        "boot.hex",
        "model.json",
        "test_meta.svh",
        *[f"sram{i}.{ext}" for i in range(10) for ext in ["bin", "hex"]],
    ]:
        assert (canonical / name).read_bytes() == (generated / name).read_bytes(), name
    executable = str(Path(directory) / "software-check")
    subprocess.run(
        [
            "gcc",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(NPU / "tests/stream_config.c"),
            "-o",
            executable,
        ],
        check=True,
    )
    software = subprocess.check_output([executable], text=True).strip()


def collect_ppa(run, current):
    run = run.resolve()
    manifest = json.loads((run / "source_manifest.json").read_text())
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text(), run
    assert "No unresolved references" in (run / "reports/unresolved.rpt").read_text(), run
    if not current:
        assert manifest["git_commit"].startswith("6697d58"), run
    for filename, expected in manifest["source_sha256"].items():
        assert sha(run / "inputs" / filename) == expected, (run, filename)
        if current:
            assert sha(ROOT / filename) == expected, (run, filename)
        else:
            blob = subprocess.check_output(["git", "show", "6697d58:" + filename], cwd=ROOT)
            assert hashlib.sha256(blob).hexdigest() == expected, (run, filename)
    for filename, expected in json.loads((run / "library_manifest.json").read_text()).items():
        assert sha(Path(filename)) == expected, filename
    assert (
        manifest["synth_period_ns"] == 18
        and manifest["report_period_ns"] == 20
        and manifest["clock_gating"]
        and manifest["unit_boundaries_preserved"]
    )
    out = run / "area_distribution.json"
    subprocess.run(
        [
            "python3.12",
            str(NPU / "eda/tsmc180/collect_module_area.py"),
            "--run",
            str(run),
            "--out",
            str(out),
        ],
        check=True,
        capture_output=True,
    )
    area = json.loads(out.read_text())
    timing = {}
    for filename, period in [("optimized_synth_clock_qor.rpt", 18), ("qor.rpt", 20)]:
        groups = {}
        for line in (run / "reports" / filename).read_text().splitlines():
            m = re.fullmatch(r"\s*(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s*", line)
            if m:
                groups[m[1]] = dict(
                    slack_ns=float(m[2]) / 1000,
                    tns_ns=float(m[3]) / 1000,
                    violating_paths=int(m[4]),
                )
        assert "sys_clk" in groups
        if period == 20:
            assert all(v["tns_ns"] == 0 and v["violating_paths"] == 0 for v in groups.values()), (
                groups
            )
        timing[str(period)] = groups
    critical = (run / "reports/optimized_synth_clock_timing.rpt").read_text().split("Path 2:")[0]
    return dict(
        run=str(run),
        critical_startpoint=re.search(r"Startpoint:\s*(.*)", critical)[1].strip(),
        critical_endpoint=re.search(r"Endpoint:\s*(.*)", critical)[1].strip(),
        total_area_mm2=area["total_area_mm2"],
        standard_cell_area_mm2=area["standard_cell_area_mm2"],
        modules={k: v["area_mm2"] for k, v in area["buckets"].items()},
        timing=timing,
        scope=area["scope"],
        source_manifest_sha256=sha(run / "source_manifest.json"),
        final_file_sha256={
            f: sha(run / f)
            for f in [
                "optimized.v",
                "optimized.sdc",
                "inputs/npu_asic_top.sv",
                "reports/area.rpt",
                "reports/qor.rpt",
                "reports/optimized_synth_clock_qor.rpt",
                "reports/timing.rpt",
            ]
        },
    )


ppa = collect_ppa(a.run, True) if a.run else None
baseline = collect_ppa(a.baseline_run, False) if a.baseline_run else None
if ppa and baseline:
    assert json.loads((a.run / "library_manifest.json").read_text()) == json.loads(
        (a.baseline_run / "library_manifest.json").read_text()
    )
gates = []
if ppa:
    for name in ["gate-opt_v3_latency", "gate-opt_v3_units", "gate-opt_v3_jtag"]:
        path = NPU / "build" / name / "result.json"
        gate = audit_result(path)
        raw_gate = json.loads(path.read_text())
        assert raw_gate["sha256"][str(a.run.resolve() / "optimized.v")] == sha(
            a.run.resolve() / "optimized.v"
        )
        gates.append(gate)
report = dict(
    passed=True,
    tests=results,
    extra_tests=extras,
    software_checks=software,
    gate_checks=gates,
    inference_cycles=cycles,
    baseline_cycles=23937,
    cycle_reduction_percent=(23937 - cycles[0]) / 23937 * 100,
    matrix_tasks=13,
    task_fifo_bits=dict(cnn=32, matrix=96, vector=99),
    config=json.loads((NPU / "build_config.json").read_text()),
    sync_abi="0x0002007f",
    unchanged_parameters_and_goldens=True,
    firmware_reproduced=True,
    profile=profile,
    ppa=ppa,
    baseline_ppa=baseline,
    new_pnr_performed=False,
    source_sha256={
        str(path.relative_to(ROOT)): sha(path)
        for path in [
            *sorted((NPU / "rtl").rglob("*.sv")),
            NPU / "rtl/files.f",
            NPU / "build_config.json",
            NPU / "mnist/firmware.py",
            NPU / "sw/npu.h",
        ]
    },
)
if ppa and baseline:
    report["area_delta_mm2"] = ppa["total_area_mm2"] - baseline["total_area_mm2"]
    report["area_delta_percent"] = report["area_delta_mm2"] / baseline["total_area_mm2"] * 100
out = NPU / "reports/throughput-optimization-validation.json"
out.write_text(json.dumps(report, indent=2) + "\n")
print(
    f"THROUGHPUT OPTIMIZATION AUDIT PASS suites={len(results)}+{len(extras)} cycles={cycles[0]} PPA={ppa is not None}; {software}; {out}"
)
