"""Audit SYNC v1 tests against their exact RTL, fixture and firmware hashes."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

NPU = Path(__file__).resolve().parents[1]
SUITES = [
    ("softcfg", True),
    ("quantsync", False),
    ("cnnqueues", False),
    ("queues", False),
    ("irqcontrol", False),
    ("sharedquant", True),
    ("cnnstream", True),
    ("vectorprogram", False),
    ("enginefaults", False),
    ("irqwake", True),
    ("sharedoperands", True),
    ("unitroutes", True),
    ("blocking", True),
    ("quantlayers", True),
    ("jtag", True),
]
results = []
for suite, macro in SUITES:
    path = NPU / f"build/vcs-syncobs_v2-{suite}{'-macro' if macro else ''}/result.json"
    record = json.loads(path.read_text())
    assert record["passed"] and not record["changed_during_run"], path
    for name, expected in record["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == expected, (path, name)
    assert not re.search(
        r"Warning-\[(?:IPDW|PCWM)|Error-", (path.parent / "compile.log").read_text()
    ), path
    if suite == "blocking":
        assert [
            int(re.search(r"elapsed_cycles=(\d+)", summary)[1])
            for summary in record["summaries"]
            if summary.startswith("SINGLE sample=")
        ] == [23937] * 10
    results.append(
        dict(
            suite=suite,
            result=str(path.relative_to(NPU)),
            summaries=record["summaries"],
        )
    )
with tempfile.TemporaryDirectory(prefix="mynpu-sync-check-") as directory:
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
    software = subprocess.run(
        [executable], text=True, capture_output=True, check=True
    ).stdout.strip()
report = dict(
    passed=True,
    observation_abi="0x0001003f",
    readonly=True,
    counter_bits=640,
    write_classification_bits=3,
    configuration_banks_added=0,
    task_fifo_widths=dict(cnn=32, matrix=96, vector=99),
    scheduling_protection_added=False,
    default_inference_cycles=23937,
    synthesis_or_pnr_rerun=False,
    software_checks=software,
    tests=results,
)
out = NPU / "reports/sync-observation-validation.json"
out.write_text(json.dumps(report, indent=2) + "\n")
print(f"SYNC OBSERVATION AUDIT PASS suites={len(results)}; {software}; {out}")
