"""Audit software-owned runtime configuration and unchanged production inference."""

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
    NPU / f"build/vcs-softcfg_v1-{suite}{'-macro' if macro else ''}/result.json"
    for suite, macro in [
        ("softcfg", True),
        ("cnnqueues", False),
        ("queues", False),
        ("sharedquant", True),
        ("irqcontrol", False),
        ("cnnstream", True),
        ("vectorprogram", False),
        ("irqwake", True),
        ("unitroutes", True),
        ("sharedoperands", True),
        ("blocking", True),
        ("quantlayers", True),
        ("jtag", True),
    ]
]
paths += [
    NPU / f"build/vcs-softcfg_v1_depth16-{suite}/result.json" for suite in ["queues", "cnnqueues"]
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
        assert [
            int(re.search(r"elapsed_cycles=(\d+)", s)[1])
            for s in record["summaries"]
            if s.startswith("SINGLE sample=")
        ] == [23937] * 10
    results.append(
        dict(
            result=str(path.relative_to(NPU)),
            suite=record["suite"],
            matrix_queue_depth=record["matrix_queue_depth"],
            vector_queue_depth=record["vector_queue_depth"],
            cnn_queue_depth=record["cnn_queue_depth"],
            summaries=record["summaries"],
        )
    )
assert len(results) == 15
canonical = NPU / "mnist/artifacts"
model = json.loads((canonical / "model.json").read_text())
assert model["operator_abi"] == "2.2" and model["shared_quant"] and model["stream_abi"] == "SD95"
baseline = subprocess.run(
    ["git", "show", "65ea66f:npu/mnist/artifacts/boot.bin"],
    cwd=NPU.parent,
    capture_output=True,
    check=True,
).stdout
assert baseline == (canonical / "boot.bin").read_bytes()
with tempfile.TemporaryDirectory(prefix="mynpu-software-config-") as directory:
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
    operator_abi="2.2",
    runtime_config_cap="0x0000000f",
    hardware_config_busy_guards=False,
    software_api_busy_guards=False,
    cnn_config_sampling="dispatch; active stays old, queued reads latest",
    vector_program_sampling="count/loop per job; instruction words live",
    quant_config_sampling="arithmetic per accepted result; enable/pack/dst live",
    matrix_config_sampling="task snapshot at submission",
    configuration_double_buffer_added=False,
    dispatch_pause_added=False,
    default_shared_quant=True,
    cycles=23937,
    baseline_ref="65ea66f",
    production_boot_binary_unchanged=True,
    firmware_reproduced=True,
    c_check=c_check,
    ppa_measured=False,
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
(NPU / "reports/software-config-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(
    f"PASS {len(results)} source-audited suites; live config sampling; unchanged 23937 cycles; {c_check}"
)
