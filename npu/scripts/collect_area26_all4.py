"""Audit the all-four task-queue configuration and its sub-2.6mm2 ASIC result."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from collect_layout_events import NPU, ROOT, audit, cases, cpu, ppa, sha, test_dir


def inference(directory):
    rows = [
        int(v)
        for v in re.findall(
            r"^SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", (directory / "run.log").read_text(), re.M
        )
    ]
    assert len(rows) == 10, directory
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument(
        "--baseline-run", type=Path, default=ROOT.parent / "eda-runs/20261108-layout-events-v1"
    )
    args = parser.parse_args()
    run = args.run.resolve()
    baseline_run = args.baseline_run.resolve()
    core = [
        ("blocking", 1),
        ("layoutevents", 1),
        ("quantlayers", 1),
        ("jtag", 1),
        ("purecompute", 0),
        ("vectorprogram", 0),
        ("sharedquant", 1),
        ("quantsync", 0),
        ("readbatch", 0),
        ("storepack", 0),
        ("cnnstream", 1),
        ("unitroutes", 1),
        ("sharedoperands", 1),
        ("matrixtiles", 1),
        ("queues", 0),
        ("irqcontrol", 0),
        ("irqwake", 1),
        ("enginefaults", 0),
        ("cnnqueues", 0),
        ("xbarstream", 0),
        ("rfsink", 0),
        ("regfile", 0),
        ("unitsmoke", 0),
        ("vectorsimd", 1),
        ("outergemm", 1),
    ]
    tests = [
        dict(suite=suite, **audit(test_dir("area26-all4-final", suite, bool(macro))))
        for suite, macro in core
    ]
    tests.append(dict(suite="softcfg", **audit(test_dir("area26-all4-fixed", "softcfg"))))
    native_dir = test_dir("area26-sw-final", "workloads")
    legacy_dir = test_dir("area26-sw-final", "workloadlegacy")
    cpu_dir = test_dir("area26-sw-final", "workloadcpu")
    old_cpu_dir = test_dir("area26-cpu-legacy", "workloadcpu")
    extras = [
        audit(d)
        for d in [
            native_dir,
            legacy_dir,
            cpu_dir,
            old_cpu_dir,
            test_dir("area26-base8", "blocking"),
            test_dir("area26-queueirq", "blocking"),
        ]
    ]
    native, legacy = cases(native_dir), cases(legacy_dir)
    assert len(native) == 23 and sum(row["checks"] for row in native.values()) == 1302
    assert native["cnn-wide-row-eight-windows"]["checks"] == 129
    assert native["rf-gemv-activation"]["overlap"] == 0
    manifest = json.loads((cpu_dir / "workloads_manifest.json").read_text())
    variants = {}
    for name in ["layout", "packed", "cnn"]:
        directory = test_dir("area26-cpu-" + name, "workloadcpu")
        extras.append(audit(directory))
        variants[name] = dict(**cpu(directory), checks=manifest["cpu_variants"][name]["checks"])
    current_cycles = inference(test_dir("area26-all4-final", "blocking"))
    baseline_cycles = inference(test_dir("area26-base8", "blocking"))
    irq_cycles = inference(test_dir("area26-queueirq", "blocking"))
    assert (
        current_cycles == [21008] * 10
        and baseline_cycles == [20728] * 10
        and irq_cycles == [20944] * 10
    )
    software = {}
    with tempfile.TemporaryDirectory(prefix="npu-all4-") as temporary:
        directory = Path(temporary)
        commands = [
            ("python_contract", [sys.executable, str(NPU / "tests/test_task_graph.py")]),
            ("format", [sys.executable, str(ROOT / "tools/format_code.py"), "--check"]),
        ]
        for name in ["stream_config", "plan_executor", "cnn_enqueue"]:
            commands.extend(
                [
                    (
                        name + "_compile",
                        [
                            "cc",
                            "-std=c11",
                            "-Wall",
                            "-Wextra",
                            "-Werror",
                            str(NPU / "tests" / f"{name}.c"),
                            "-o",
                            str(directory / name),
                        ],
                    ),
                    (name, [str(directory / name)]),
                ]
            )
        for name, command in commands:
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            assert result.returncode == 0, (name, result.stdout, result.stderr)
            software[name] = dict(passed=True, output=(result.stdout + result.stderr).strip())
    physical = ppa(run, live=True)
    baseline = ppa(baseline_run)
    match = [
        "effort",
        "synth_period_ns",
        "report_period_ns",
        "clock_gating",
        "unit_boundaries_preserved",
        "sram_banks",
        "rf_bank_words",
        "stream_fifo_depth",
    ]
    assert all(physical["settings"][name] == baseline["settings"][name] for name in match)
    assert all(
        physical["settings"][key] == 4 and baseline["settings"][key] == 8
        for key in ["matrix_queue_depth", "vector_queue_depth", "cnn_queue_depth"]
    )
    assert (run / "synth.sdc").read_bytes() == (baseline_run / "synth.sdc").read_bytes()
    assert json.loads((run / "library_manifest.json").read_text()) == json.loads(
        (baseline_run / "library_manifest.json").read_text()
    )
    assert physical["total_area_mm2"] < 2.6
    assert all(
        g["tns_ns"] == 0 and g["violating_paths"] == 0
        for g in physical["synth_clock_groups"].values()
    )
    gates = []
    for suite in ["latency", "units", "layout", "jtag"]:
        directory = NPU / f"build/gate-area26_all4_{suite}"
        gates.append(audit(directory))
        record = json.loads((directory / "result.json").read_text())
        assert record["sha256"][str(run / "optimized.v")] == sha(run / "optimized.v")
    config = json.loads((NPU / "build_config.json").read_text())
    assert [config[k] for k in ["matrix_queue_depth", "vector_queue_depth", "cnn_queue_depth"]] == [
        4,
        4,
        4,
    ]
    diagram = json.loads((NPU / "docs/images/architecture-detailed.source.json").read_text())
    for name, expected in diagram["source_sha256"].items():
        assert sha(ROOT / name) == expected, name
    inputs = [
        *sorted((NPU / "rtl").rglob("*.sv")),
        NPU / "rtl/files.f",
        NPU / "build_config.json",
        NPU / "sw/npu.h",
        NPU / "sw/task_graph.py",
        NPU / "workloads/generate.py",
        NPU / "tests/cnn_enqueue.c",
        NPU / "tb/tb_software_config.sv",
        NPU / "eda/tsmc180/draw_architecture.py",
        NPU / "docs/images/architecture-detailed.png",
        NPU / "docs/images/architecture-detailed.svg",
        NPU / "docs/images/architecture-detailed.source.json",
        Path(__file__).resolve(),
    ]
    delta = physical["total_area_mm2"] - baseline["total_area_mm2"]
    report = dict(
        passed=True,
        area_goal_met=True,
        area_target_mm2=2.6,
        config=config,
        tests=tests,
        extra_tests=extras,
        software_checks=software,
        gate_tests=gates,
        mnist_cycles=current_cycles,
        baseline_mnist_cycles=baseline_cycles,
        mnist_cycle_delta=280,
        mnist_cycle_delta_percent=280 / 20728 * 100,
        optional_queue_irq_cycles=irq_cycles,
        queue_irq_is_default=False,
        task_fifo_bits=dict(matrix=125, vector=166, cnn=48),
        task_fifo_payload_bits=dict(old=2712, current=1356, saved=1356),
        native_cases=native,
        legacy_cases=legacy,
        real_cpu=dict(native=cpu(cpu_dir), legacy=cpu(old_cpu_dir), variants=variants),
        ppa=physical,
        baseline_ppa=baseline,
        area_delta_mm2=delta,
        area_reduction_percent=-delta / baseline["total_area_mm2"] * 100,
        wide_cnn_row=dict(
            width=128,
            windows=8,
            queue_depth=4,
            c_api="npu_cnn_start_wait and npu_cnn_layer stream windows with bounded queue-space waits",
        ),
        new_pnr_performed=False,
        scope="Only three task FIFO capacities changed; data stream FIFOs remain 8 words, RF256B and compute features retained.",
        caveats=[
            "Mapped cell area includes SRAM, excludes PAD/CTS/routing; setup is synthesis STA.",
            "Default MNIST has 280 extra cycles. Queue IRQ wait is an optional separately tested firmware image.",
            "C enqueue mock tests queue semantics, not arithmetic; real SoC wide-row test checks all 128 outputs.",
            "Legacy nonblocking C row entry retains its whole-row-capacity contract; use start_wait/layer for wide rows.",
            "Historical 8/8/8 layout-events validation is retained as a prior checkpoint.",
        ],
        source_sha256={str(p.relative_to(ROOT)): sha(p) for p in inputs},
    )
    target = NPU / "reports/area26-all4-validation.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(
        "AREA26 ALL4 VALIDATION PASS",
        physical["total_area_mm2"],
        physical["synth_clock_groups"]["sys_clk"],
        current_cycles[0],
    )
    print(target)


if __name__ == "__main__":
    main()
