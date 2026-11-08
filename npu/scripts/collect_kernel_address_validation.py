"""Audit SD92 kernel-address queues and both regenerated inference images."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

NPU = Path(__file__).resolve().parents[1]
paths = [
    NPU / f"build/vcs-kernel_v1-{suite}{'-macro' if macro else ''}/result.json"
    for suite, macro in [
        ("cnnqueues", False),
        ("cnnstream", True),
        ("irqcontrol", False),
        ("irqwake", True),
        ("sharedquant", True),
        ("unitroutes", True),
    ]
]
paths.append(NPU / "build/vcs-kernel_v1_depth16-cnnqueues/result.json")
for variant in ["default", "quant"]:
    for suite in ["blocking", "quantlayers", "jtag"]:
        paths.append(NPU / f"build/vcs-kernel_v1_{variant}-{suite}-macro/result.json")
results, cycles = [], {}
for path in paths:
    result = json.loads(path.read_text())
    assert result["passed"] and not result["changed_during_run"], path
    for name, sha in result["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (path, name)
    log = (path.parent / "compile.log").read_text()
    assert not re.search(r"Warning-\[(?:IPDW|PCWM)|Error-", log), path
    results.append(
        dict(
            result=str(path.relative_to(NPU)),
            suite=result["suite"],
            macro=result["macro"],
            cnn_queue_depth=result["cnn_queue_depth"],
            summaries=result["summaries"],
            result_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        )
    )
    if result["suite"] == "blocking":
        measured = [
            int(re.search(r"elapsed_cycles=(\d+)", s)[1])
            for s in result["summaries"]
            if s.startswith("SINGLE sample=")
        ]
        assert len(measured) == 10 and len(set(measured)) == 1
        cycles["quant" if "_quant-" in path.parent.name else "default"] = measured[0]
assert len(results) == 13 and cycles == dict(default=29297, quant=26061)
source = NPU / "build/kernel-v1-default-artifacts"
canonical = NPU / "mnist/artifacts"
for name in [
    "boot.S",
    "boot.bin",
    "boot.hex",
    "model.json",
    "test_meta.svh",
    *[f"sram{i}.{ext}" for i in range(10) for ext in ["bin", "hex"]],
]:
    assert (source / name).read_bytes() == (canonical / name).read_bytes(), name
for variant in ["default", "quant"]:
    artifacts = NPU / f"build/kernel-v1-{variant}-artifacts"
    assert json.loads((artifacts / "model.json").read_text())["stream_abi"] == "SD92"
    for name in [
        "params.hex",
        *[f"input{i}.hex" for i in range(10)],
        *[f"gold{i}_{layer}.hex" for i in range(10) for layer in range(6)],
    ]:
        assert (artifacts / name).read_bytes() == (canonical / name).read_bytes(), name
with tempfile.TemporaryDirectory(prefix="mynpu-kernel-check-") as directory:
    executable = str(Path(directory) / "stream_config")
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
    c_check = subprocess.run(
        [executable], capture_output=True, text=True, check=True
    ).stdout.strip()
report = dict(
    passed=True,
    stream_abi="SD92",
    stream_abi_value="0x53443932",
    task_fifo_bits=43,
    window_shadow_bits=32,
    kernel_address_bits=15,
    queue_bits_added_at_depth8=88,
    cycles=cycles,
    cycles_before=dict(default=29298, quant=25965),
    c_check=c_check,
    ppa_measured=False,
    suites=results,
    rtl_sha256={
        str(p.relative_to(NPU)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((NPU / "rtl").rglob("*.sv"))
    },
)
(NPU / "reports/kernel-address-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"PASS {len(results)} source-audited suites; SD92 43-bit FIFO; cycles {cycles}; {c_check}")
