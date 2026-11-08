"""Audit SD95 count1..16, dynamic RF partial spans and production QT01 images."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NPU = Path(__file__).resolve().parents[1]
paths = [
    NPU
    / f"build/vcs-count16_{'v3' if suite in ['cnnstream', 'sharedquant'] else 'v2'}-{suite}{'-macro' if macro else ''}/result.json"
    for suite, macro in [
        ("cnnstream", True),
        ("sharedquant", True),
        ("unitroutes", True),
        ("sharedoperands", True),
        ("irqwake", True),
        ("irqcontrol", False),
        ("blocking", True),
        ("quantlayers", True),
        ("jtag", True),
    ]
]
paths += [
    NPU / f"build/{tag}-cnnqueues/result.json"
    for tag in ["vcs-count16_v3", "vcs-count16_v3_depth16"]
]
results = []
for path in paths:
    record = json.loads(path.read_text())
    assert record["passed"] and not record["changed_during_run"], path
    for name, sha in record["sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha, (path, name)
    assert not re.search(
        r"Warning-\[(?:IPDW|PCWM)|Error-", (path.parent / "compile.log").read_text()
    ), path
    if record["suite"] == "blocking":
        cycles = [
            int(re.search(r"elapsed_cycles=(\d+)", s)[1])
            for s in record["summaries"]
            if s.startswith("SINGLE sample=")
        ]
        assert cycles == [23937] * 10
    results.append(
        dict(
            result=str(path.relative_to(NPU)),
            suite=record["suite"],
            cnn_queue_depth=record["cnn_queue_depth"],
            macro=record["macro"],
            summaries=record["summaries"],
        )
    )
canonical = NPU / "mnist/artifacts"
model = json.loads((canonical / "model.json").read_text())
assert model["shared_quant"] and model["stream_abi"] == "SD95" and model["stream_tasks"] == 212
with tempfile.TemporaryDirectory(prefix="mynpu-count16-") as directory:
    generated = Path(directory) / "artifacts"
    shutil.copytree(canonical, generated)
    env = os.environ.copy()
    env.pop("NPU_SHARED_QUANT", None)
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
    c_check = subprocess.run(
        [executable], text=True, capture_output=True, check=True
    ).stdout.strip()
report = dict(
    passed=True,
    stream_abi="SD95",
    stream_abi_value="0x53443935",
    count_field_bits=[3, 0],
    actual_count_range=[1, 16],
    task_bits=32,
    configuration_double_buffer_implemented=False,
    default_shared_quant=True,
    cycles=23937,
    cycles_before=26067,
    cnn_tasks=212,
    cnn_tasks_before=296,
    rf_bytes=256,
    maximum_partial_bytes=64,
    partial_span_checked_at_start=True,
    partial_bytes_per_cnn_layer=[56, 56, 28, 12, 12],
    firmware_reproduced=True,
    ppa_measured=False,
    c_check=c_check,
    suites=results,
    rtl_sha256={
        str(p.relative_to(NPU)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((NPU / "rtl").rglob("*.sv"))
    },
    software_sha256={
        str(p.relative_to(NPU)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [NPU / "mnist/firmware.py", NPU / "sw/npu.h", NPU / "tests/stream_config.c"]
    },
)
(NPU / "reports/count16-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"PASS {len(results)} source-audited suites; SD95 count1..16 FIFO32; 23937 cycles; {c_check}")
