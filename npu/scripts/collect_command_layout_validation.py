"""Audit SD93 shared kernels, Matrix task formats/stream tiles and VPG3."""

import hashlib
import json
from pathlib import Path
import re
import os
import shutil
import subprocess
import tempfile

NPU = Path(__file__).resolve().parents[1]
paths = [
    NPU / f"build/vcs-command_v3-{suite}{'-macro' if macro else ''}/result.json"
    for suite, macro in [
        ("cnnqueues", False),
        ("cnnstream", True),
        ("vectorprogram", False),
        ("matrixtiles", True),
        ("vectorsimd", True),
        ("unitroutes", True),
        ("sharedquant", True),
        ("irqwake", True),
        ("irqcontrol", False),
        ("enginefaults", False),
    ]
]
paths += [
    NPU / f"build/{name}/result.json"
    for name in [
        "vcs-command_v3_depth16-cnnqueues",
        "vcs-command_v4-outergemm-macro",
        "vcs-command_v5-queues",
        "vcs-command_v5_depth16-queues",
    ]
]
for variant in ["default", "quant"]:
    for suite in ["blocking", "quantlayers", "jtag"]:
        paths.append(NPU / f"build/vcs-command_v3_{variant}-{suite}-macro/result.json")
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
assert len(results) == 20 and cycles == dict(default=30835, quant=26067)
source = NPU / "build/command-v1-default-artifacts"
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
    artifacts = NPU / f"build/command-v1-{variant}-artifacts"
    assert json.loads((artifacts / "model.json").read_text())["stream_abi"] == "SD93"
    for name in [
        "params.hex",
        *[f"input{i}.hex" for i in range(10)],
        *[f"gold{i}_{layer}.hex" for i in range(10) for layer in range(6)],
    ]:
        assert (artifacts / name).read_bytes() == (canonical / name).read_bytes(), name
# Reproduce both tested images from current assembler sources without touching production assets.
for variant in ["default", "quant"]:
    source_artifacts = NPU / f"build/command-v1-{variant}-artifacts"
    with tempfile.TemporaryDirectory(prefix="mynpu-command-reproduce-") as directory:
        reproduced = Path(directory) / "artifacts"
        shutil.copytree(source_artifacts, reproduced)
        env = os.environ.copy()
        env["NPU_ARTIFACTS_DIR"] = str(reproduced)
        env["NPU_SHARED_QUANT"] = "1" if variant == "quant" else "0"
        subprocess.run(
            ["python3.12", str(NPU / "mnist/firmware.py")],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        for name in [
            "boot.S",
            "boot.bin",
            "boot.hex",
            "model.json",
            "test_meta.svh",
            *[f"sram{i}.{ext}" for i in range(10) for ext in ["bin", "hex"]],
        ]:
            assert (reproduced / name).read_bytes() == (source_artifacts / name).read_bytes(), (
                variant,
                name,
            )
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
    stream_abi="SD93",
    stream_abi_value="0x53443933",
    task_fifo_bits=32,
    window_shadow_bits=32,
    kernel_address_bits=15,
    kernel_address_shared=True,
    matrix_task_bits=96,
    vector_task_bits=99,
    vector_program_abi="VPG3",
    matrix_strides_per_task=True,
    matrix_stream_order="tile/K/A-rows/B-cols; one word per operand",
    cnn_queue_bits_removed_at_depth8=88,
    cycles=cycles,
    cycles_before=dict(default=29297, quant=26061),
    c_check=c_check,
    ppa_measured=False,
    firmware_reproduced=True,
    software_sha256={
        str(p.relative_to(NPU)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [NPU / "mnist/firmware.py", NPU / "sw/npu.h", NPU / "tests/stream_config.c"]
    },
    suites=results,
    rtl_sha256={
        str(p.relative_to(NPU)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((NPU / "rtl").rglob("*.sv"))
    },
)
(NPU / "reports/command-layout-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"PASS {len(results)} source-audited suites; SD93/Matrix4/VPG3; cycles {cycles}; {c_check}")
