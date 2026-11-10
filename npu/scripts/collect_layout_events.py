"""Audit LY01/EV01 regressions, matched software comparison and final ASIC PPA."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from sim_sources import macro_wrapper

NPU = Path(__file__).resolve().parents[1]
ROOT = NPU.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(directory):
    path = directory / "result.json"
    record = json.loads(path.read_text())
    assert record["passed"] and not record["changed_during_run"], path
    for name, expected in record["sha256"].items():
        assert sha(Path(name)) == expected, (path, name)
    assert not re.search(
        r"Error-|Warning-\[(?:IPDW|PCWM|SIOB)", (directory / "compile.log").read_text()
    ), path
    return dict(result=str(path.relative_to(NPU)), summaries=record["summaries"])


def test_dir(tag, suite, macro=True):
    return NPU / f"build/vcs-{tag}-{suite}{'-macro' if macro else ''}"


def cases(directory):
    names = json.loads((directory / "workloads_manifest.json").read_text())["cases"]
    log = (directory / "run.log").read_text()
    rows = {}
    for i, name in enumerate(names):
        lines = [
            line for line in log.splitlines() if re.match(rf"WORKLOAD(?:_PROFILE)? case={i} ", line)
        ]
        assert len(lines) == 2, (name, lines)
        row = {k: int(v) for line in lines for k, v in re.findall(r"(\w+)=(\d+)", line)}
        row.pop("case")
        rows[name] = row
    return rows


def cpu(directory):
    text = (directory / "run.log").read_text()
    match = re.search(r"GENERAL CPU PASS words=(\d+) cycles=(\d+)", text)
    profile = re.search(r"^GENERAL_CPU_PROFILE (.*)$", text, re.M)
    assert match and profile
    bins = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", profile[1])}
    reasons = [
        "reset_boot",
        "wfi",
        "lsu_sram",
        "lsu_mmio",
        "lsu_rf",
        "lsu_fifo",
        "lsu_other",
        "fetch",
        "load_hazard",
        "jump_hazard",
        "pipeline",
        "other_awake",
    ]
    assert sum(bins[k] for k in reasons) == bins["cycles"] == int(match[2])
    return dict(words=int(match[1]), cycles=int(match[2]), profile=bins)


def timing(path):
    text = path.read_text()
    groups = {
        name: dict(
            slack_ns=float(slack) / 1000, tns_ns=float(tns) / 1000, violating_paths=int(paths)
        )
        for name, slack, tns, paths in re.findall(
            r"^([\w_]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s*$", text, re.M
        )
        if name != "Total"
    }
    assert "sys_clk" in groups and "jtag_clk" in groups, path
    return groups


def ppa(run, live=False):
    manifest = json.loads((run / "source_manifest.json").read_text())
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text()
    if live:
        for name, expected in manifest["source_sha256"].items():
            assert sha(ROOT / name) == expected, name
            frozen = run / "inputs" / name
            if frozen.is_file():
                assert sha(frozen) == expected, frozen
        assert (run / "inputs/npu_asic_top.sv").read_text() == macro_wrapper(
            (NPU / "rtl/top/npu_soc.sv").read_text(), top="npu_asic_top"
        )
    for name, expected in json.loads((run / "library_manifest.json").read_text()).items():
        assert sha(Path(name)) == expected, name
    output = run / "area_distribution.json"
    subprocess.run(
        [
            sys.executable,
            str(NPU / "eda/tsmc180/collect_module_area.py"),
            "--run",
            str(run),
            "--out",
            str(output),
        ],
        check=True,
        capture_output=True,
    )
    area = json.loads(output.read_text())
    unresolved = (run / "reports/unresolved.rpt").read_text()
    assert "No unresolved references" in unresolved and "No empty modules" in unresolved
    synth = timing(run / "reports/optimized_synth_clock_qor.rpt")
    report = timing(run / "reports/qor.rpt")
    path_text = (run / "reports/optimized_synth_clock_timing.rpt").read_text()
    critical = {
        key: re.search(rf"^\s*{key}: (.*)$", path_text, re.M)[1]
        for key in ["Startpoint", "Endpoint"]
    }
    return dict(
        run=str(run),
        total_area_mm2=area["total_area_mm2"],
        standard_cell_area_mm2=area["standard_cell_area_mm2"],
        buckets=area["buckets"],
        synth_clock_groups=synth,
        report_clock_groups=report,
        critical_path=critical,
        settings={
            k: manifest[k]
            for k in [
                "effort",
                "synth_period_ns",
                "report_period_ns",
                "clock_gating",
                "unit_boundaries_preserved",
                "sram_banks",
                "rf_bank_words",
                "stream_fifo_depth",
                "matrix_queue_depth",
                "vector_queue_depth",
                "cnn_queue_depth",
            ]
        },
        files_sha256={
            str(p.relative_to(run)): sha(p)
            for p in [
                run / "optimized.v",
                run / "synth.sdc",
                run / "report.sdc",
                run / "source_manifest.json",
                run / "reports/area.rpt",
                run / "reports/optimized_synth_clock_qor.rpt",
                run / "reports/qor.rpt",
            ]
        },
        scope="mapped cell area including two SRAM macros; no PAD, CTS, routing or SDF",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument(
        "--baseline-run", type=Path, default=ROOT.parent / "eda-runs/20261108-optimization-v4"
    )
    args = parser.parse_args()
    run = args.run.resolve()
    core = [
        ("quantlayers", 1),
        ("jtag", 1),
        ("purecompute", 0),
        ("vectorprogram", 0),
        ("sharedquant", 1),
        ("quantsync", 0),
        ("readbatch", 0),
        ("storepack", 0),
        ("softcfg", 1),
        ("cnnstream", 1),
        ("unitroutes", 1),
        ("sharedoperands", 1),
        ("matrixtiles", 1),
        ("queues", 0),
        ("irqcontrol", 0),
        ("irqwake", 1),
        ("enginefaults", 0),
        ("xbarstream", 0),
        ("rfsink", 0),
        ("regfile", 0),
        ("unitsmoke", 0),
        ("vectorsimd", 1),
        ("outergemm", 1),
        ("layoutevents", 1),
    ]
    tests = [
        dict(suite=suite, **audit(test_dir("layout-final-v1", suite, bool(macro))))
        for suite, macro in core
    ]
    tests.append(dict(suite="cnnqueues", **audit(test_dir("layout-final-v3", "cnnqueues", False))))
    native_dir = test_dir("layout-final-v5", "workloads")
    legacy_dir = test_dir("layout-final-v5", "workloadlegacy")
    cpu_dir = test_dir("layout-final-v5", "workloadcpu")
    old_cpu_dir = test_dir("layout-cpu-legacy-v5", "workloadcpu")
    extra = [
        audit(path)
        for path in [
            native_dir,
            legacy_dir,
            cpu_dir,
            old_cpu_dir,
            test_dir("layout-serial-v5", "workloads"),
            test_dir("layout-depth1-v5", "workloads"),
            test_dir("layout-preppa", "blocking"),
        ]
    ]
    native, legacy = cases(native_dir), cases(legacy_dir)
    assert len(native) == 22 and len(legacy) == 19
    assert sum(c["checks"] for c in native.values()) == 1173
    assert all(native[name]["checks"] == row["checks"] for name, row in legacy.items())
    assert native["rf-gemv-activation"]["overlap"] == 0
    serial = cases(test_dir("layout-serial-v5", "workloads"))
    assert (
        serial["rf-gemv-activation"]["checks"] == 2 and serial["rf-gemv-activation"]["overlap"] == 0
    )
    comparisons = {
        name: dict(
            legacy=row,
            native=native[name],
            cycle_reduction_percent=(row["cycles"] - native[name]["cycles"]) / row["cycles"] * 100,
        )
        for name, row in legacy.items()
    }
    new_cpu, old_cpu = cpu(cpu_dir), cpu(old_cpu_dir)
    variants = {}
    variant_manifest = json.loads((cpu_dir / "workloads_manifest.json").read_text())["cpu_variants"]
    for name in ["layout", "packed", "cnn"]:
        directory = test_dir("layout-cpu-" + name + "-v5", "workloadcpu")
        extra.append(audit(directory))
        variants[name] = dict(**cpu(directory), checks=variant_manifest[name]["checks"])
    inference = [
        int(v)
        for v in re.findall(
            r"^SINGLE sample=\d+ .*?elapsed_cycles=(\d+)",
            (test_dir("layout-preppa", "blocking") / "run.log").read_text(),
            re.M,
        )
    ]
    assert inference == [20728] * 10
    sw = {}
    with tempfile.TemporaryDirectory(prefix="npu-layout-") as temporary:
        output = Path(temporary)
        generated = output / "generated.c"
        generated.write_text(
            '#include "workload_cpu_plan.h"\nint main(void) { return sizeof(npu_cpu_workload)==0; }\n'
        )
        commands = [
            ("python_contract", [sys.executable, str(NPU / "tests/test_task_graph.py")]),
            (
                "c_layout_compile",
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(NPU / "tests/stream_config.c"),
                    "-o",
                    str(output / "layout"),
                ],
            ),
            ("c_layout", [str(output / "layout")]),
            (
                "c_executor_compile",
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(NPU / "tests/plan_executor.c"),
                    "-o",
                    str(output / "executor"),
                ],
            ),
            ("c_executor", [str(output / "executor")]),
            (
                "generated_c",
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-fsyntax-only",
                    "-I" + str(NPU / "sw"),
                    "-I" + str(cpu_dir),
                    str(generated),
                ],
            ),
            ("format", [sys.executable, str(ROOT / "tools/format_code.py"), "--check"]),
        ]
        for name, command in commands:
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            assert result.returncode == 0, (name, result.stdout, result.stderr)
            sw[name] = dict(passed=True, output=(result.stdout + result.stderr).strip())
    physical = ppa(run, live=True)
    baseline = ppa(args.baseline_run.resolve())
    assert physical["settings"] == baseline["settings"]
    assert (run / "synth.sdc").read_bytes() == (args.baseline_run / "synth.sdc").read_bytes()
    assert json.loads((run / "library_manifest.json").read_text()) == json.loads(
        (args.baseline_run / "library_manifest.json").read_text()
    )
    gates = []
    for suite in ["latency", "units", "layout", "jtag"]:
        directory = NPU / f"build/gate-layout_v1_{suite}"
        gate = audit(directory)
        record = json.loads((directory / "result.json").read_text())
        assert record["sha256"][str(run / "optimized.v")] == sha(run / "optimized.v")
        gates.append(gate)
    report = dict(
        passed=True,
        tests=tests,
        extra_tests=extra,
        software_checks=sw,
        gate_tests=gates,
        task_fifo_bits=dict(matrix=125, vector=166, cnn=48, cnn_command=32, cnn_event_sidecar=16),
        config=json.loads((NPU / "build_config.json").read_text()),
        hardware_events=dict(
            bits=8, wait_consumes=False, signal_after_write_ack=True, signal_on_fault=False
        ),
        workload_comparison=comparisons,
        native_cases=native,
        native_common_host_cycles=sum(native[name]["cycles"] for name in legacy),
        legacy_common_host_cycles=sum(row["cycles"] for row in legacy.values()),
        real_cpu=dict(
            native=new_cpu,
            legacy=old_cpu,
            checks=7,
            cycle_reduction_percent=(old_cpu["cycles"] - new_cpu["cycles"])
            / old_cpu["cycles"]
            * 100,
        ),
        real_cpu_variants=variants,
        mnist_cycles=inference,
        ppa=physical,
        baseline_ppa=baseline,
        area_delta_mm2=physical["total_area_mm2"] - baseline["total_area_mm2"],
        new_pnr_performed=False,
        caveats=[
            "Host case cycles include data loading and golden reads; not inference latency.",
            "CPU bins partition time; other_awake includes execution and unclassified awake cycles.",
            "Full model regression is MNIST; attention test is only QK-transpose and row-max primitives.",
            "Shared program/geometry and event reuse lifetimes remain software-owned.",
            "The old general-workloads-validation.json is a historical software-only checkpoint.",
        ],
        source_sha256={
            str(p.relative_to(ROOT)): sha(p)
            for p in [
                *sorted((NPU / "rtl").rglob("*.sv")),
                NPU / "rtl/files.f",
                NPU / "sw/npu.h",
                NPU / "sw/task_graph.py",
                NPU / "sw/plan_rv32.py",
                NPU / "workloads/generate.py",
                NPU / "scripts/run_vcs.py",
                NPU / "scripts/run_gate.py",
                NPU / "eda/tsmc180/draw_architecture.py",
                NPU / "docs/images/architecture-detailed.png",
                NPU / "docs/images/architecture-detailed.svg",
                NPU / "docs/images/architecture-detailed.source.json",
                Path(__file__).resolve(),
            ]
        },
    )
    target = NPU / "reports/layout-events-validation.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(
        "LAYOUT EVENTS VALIDATION PASS",
        physical["total_area_mm2"],
        physical["synth_clock_groups"]["sys_clk"],
        new_cpu["cycles"],
    )
    print(target)


if __name__ == "__main__":
    main()
