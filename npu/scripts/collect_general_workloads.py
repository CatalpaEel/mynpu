"""Audit general-kernel/real-CPU tests and record reproducible software costs."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

NPU = Path(__file__).resolve().parents[1]
ROOT = NPU.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(tag, suite):
    directory = NPU / f"build/vcs-{tag}-{suite}-macro"
    record = json.loads((directory / "result.json").read_text())
    assert record["passed"] and not record["changed_during_run"], directory
    for name, expected in record["sha256"].items():
        assert sha(Path(name)) == expected, (directory, name)
    assert not re.search(
        r"Error-|Warning-\[(?:IPDW|PCWM|SIOB)", (directory / "compile.log").read_text()
    ), directory
    return directory, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="general-final3")
    parser.add_argument("--regression-tag", default="general-regression")
    args = parser.parse_args()
    directory, kernels = audit(args.tag, "workloads")
    cpu_dir, cpu = audit(args.tag, "workloadcpu")
    mnist_dir, mnist = audit(args.regression_tag, "blocking")
    manifest = json.loads((directory / "workloads_manifest.json").read_text())
    log = (directory / "run.log").read_text()
    cases = []
    for index, name in enumerate(manifest["cases"]):
        lines = [
            line
            for line in log.splitlines()
            if re.match(rf"WORKLOAD(?:_PROFILE)? case={index} ", line)
        ]
        assert len(lines) == 2, (name, lines)
        row = {k: int(v) for line in lines for k, v in re.findall(r"(\w+)=(\d+)", line)}
        row["name"] = name
        cases.append(row)
    passed = re.search(
        r"GENERAL WORKLOADS PASS checks=(\d+) commands=(\d+) cycles=(\d+) overlap_cycles=(\d+)", log
    )
    assert passed
    checks, commands, cycles, overlap = map(int, passed.groups())
    assert sum(case["checks"] for case in cases) == checks
    assert len(cases) >= 19 and overlap > 0
    cpu_log = (cpu_dir / "run.log").read_text()
    cpu_summary = re.search(r"GENERAL CPU PASS words=(\d+) cycles=(\d+)", cpu_log)
    assert cpu_summary
    mnist_cycles = [
        int(v)
        for v in re.findall(
            r"^SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", (mnist_dir / "run.log").read_text(), re.M
        )
    ]
    assert mnist_cycles == [20728] * 10, mnist_cycles
    software = {}
    with tempfile.TemporaryDirectory(prefix="mynpu-general-") as temporary:
        executable = str(Path(temporary) / "plan-test")
        generated_test = Path(temporary) / "generated.c"
        generated_test.write_text(
            '#include "workload_cpu_plan.h"\n'
            "int main(void) { return sizeof(npu_cpu_workload) == 0; }\n"
        )
        for name, command in [
            ("python_contract", [sys.executable, str(NPU / "tests/test_task_graph.py")]),
            (
                "c_compile",
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(NPU / "tests/plan_executor.c"),
                    "-o",
                    executable,
                ],
            ),
            ("c_runtime", [executable]),
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
                    "-I" + str(directory),
                    str(generated_test),
                ],
            ),
            ("format", [sys.executable, str(ROOT / "tools/format_code.py"), "--check"]),
        ]:
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
            assert result.returncode == 0, (name, result.stdout, result.stderr)
            software[name] = dict(passed=True, output=(result.stdout + result.stderr).strip())
    subprocess.run(
        ["git", "diff", "--exit-code", "HEAD", "--", "npu/rtl", "npu/build_config.json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    files = [
        "sw/task_graph.py",
        "sw/plan_rv32.py",
        "sw/npu_plan.h",
        "workloads/generate.py",
        "tb/tb_workloads.sv",
        "tests/test_task_graph.py",
        "tests/plan_executor.c",
        "scripts/run_vcs.py",
        "scripts/collect_general_workloads.py",
    ]
    report = dict(
        passed=True,
        scope="General integer kernels and a small real-RV32 pipeline; not new full-model coverage.",
        rtl_modified=False,
        hardware_event_wait_signal_added=False,
        software_events="Per-unit completion tickets; CPU/host waits before dependent submission.",
        kernels=dict(
            cases=cases,
            checks=checks,
            commands=commands,
            host_cycles_including_load_and_checks=cycles,
            overlap_cycles=overlap,
            submitted=manifest["submitted"],
            result=str(directory.relative_to(NPU) / "result.json"),
        ),
        cpu=dict(
            instruction_words=int(cpu_summary[1]),
            execution_cycles=int(cpu_summary[2]),
            checks=manifest["cpu_checks"],
            result=str(cpu_dir.relative_to(NPU) / "result.json"),
        ),
        mnist=dict(
            samples=10,
            cycles_per_image=mnist_cycles,
            result=str(mnist_dir.relative_to(NPU) / "result.json"),
        ),
        software=software,
        source_sha256={name: sha(NPU / name) for name in files},
        ppa="No new synthesis: compute RTL and build configuration unchanged.",
        limitations=[
            "Generic GEMM input storage is 4 bytes per INT8/INT16 element.",
            "Reduction writes every prefix and requires 4*N scratch bytes.",
            "Irregular vector layouts use scalar tasks.",
            "No full Softmax/Transformer/MobileNet accuracy or performance claim.",
        ],
    )
    target = NPU / "reports/general-workloads-validation.json"
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"GENERAL VALIDATION PASS cases={len(cases)} checks={checks} overlap={overlap} cpu_cycles={cpu_summary[2]}"
    )
    print(target)


if __name__ == "__main__":
    main()
