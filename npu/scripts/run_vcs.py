"""Run real CPU regressions with source/asset hashes and optional SRAM macros."""

import argparse, hashlib, json, re, shutil, subprocess
from pathlib import Path
from sim_sources import macro_wrapper
from rtl_sources import rtl_file

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument(
    "--suite",
    choices=[
        "sramuncached",
        "arbiter",
        "rfequivalence",
        "readbatch",
        "sharedoperands",
        "vectorsimd",
        "ops",
        "jtag",
        "soc",
        "xbarstream",
        "unitroutes",
        "xbar",
        "xbarconcurrent",
        "queues",
        "cnnqueues",
        "cnncompute",
        "purecompute",
        "rfsink",
        "burst",
        "layers",
        "latency",
        "stream",
        "enginefaults",
        "regfile",
        "vectorprogram",
        "vectorsimd",
    ],
    required=True,
)
p.add_argument("--parallel-units", type=int, choices=[0, 1], default=1)
p.add_argument("--tag", required=True)
p.add_argument("--macro", action="store_true")
p.add_argument(
    "--matrix-queue-depth",
    type=int,
    choices=[1, 2, 4, 8, 16],
    default=json.loads((ROOT / "build_config.json").read_text())["matrix_queue_depth"],
)
p.add_argument(
    "--vector-queue-depth",
    type=int,
    choices=[1, 2, 4, 8, 16],
    default=json.loads((ROOT / "build_config.json").read_text())["vector_queue_depth"],
)
p.add_argument(
    "--cnn-queue-depth",
    type=int,
    choices=[1, 2, 4, 8, 16],
    default=json.loads((ROOT / "build_config.json").read_text())["cnn_queue_depth"],
)
p.add_argument(
    "--rf-bank-words",
    type=int,
    choices=[32, 64, 128, 256],
    default=json.loads((ROOT / "build_config.json").read_text())["rf_bank_words"],
)
p.add_argument("--max-cycles", type=int, default=0)
p.add_argument("--artifacts-dir", type=Path, default=ROOT / "mnist/artifacts")
a = p.parse_args()
if a.suite in ["dma", "stream", "soc", "layers", "ops", "burst"]:
    p.error("Legacy DMA-dependent suite retired; use jtag, latency, and independent compute suites")
a.artifacts_dir = a.artifacts_dir.resolve()
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("tag must be a simple name")
out = ROOT / "build" / ("vcs-" + a.tag + "-" + a.suite + ("-macro" if a.macro else ""))
out.mkdir(parents=True, exist_ok=False)
subprocess.run(["/usr/bin/python3.12", str(ROOT / "scripts/gen_sources.py")], check=True)
files = [Path(s) for s in (ROOT / "build/sources.f").read_text().splitlines()]
assert files, "Generated source list is empty"
tops = {
    "sramuncached": "tb_sram_uncached",
    "arbiter": "tb_arbiter",
    "rfequivalence": "tb_rf_equivalence",
    "readbatch": "tb_read_batch",
    "sharedoperands": "tb_shared_operands",
    "ops": "tb_ops",
    "jtag": "tb_jtag",
    "soc": "tb_npu_soc",
    "xbarstream": "tb_xbar_stream",
    "unitroutes": "tb_unit_routes",
    "xbar": "tb_xbar",
    "xbarconcurrent": "tb_xbar_concurrent",
    "queues": "tb_queues",
    "cnnqueues": "tb_cnn_queue",
    "cnncompute": "tb_cnn_compute",
    "purecompute": "tb_pure_compute",
    "rfsink": "tb_rf_sink",
    "burst": "tb_queue_burst",
    "layers": "tb_mnist",
    "latency": "tb_mnist_latency",
    "stream": "tb_mnist_stream",
    "enginefaults": "tb_engine_faults",
    "regfile": "tb_regfile",
    "vectorprogram": "tb_vector_program",
    "vectorsimd": "tb_vector_simd",
}
top = tops[a.suite]
tb = ROOT / "tb" / (top + ".sv")
inc = ROOT.parent / "external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include"
if a.suite in ["xbar", "xbarconcurrent", "regfile", "rfsink"]:
    files = [
        ROOT / "rtl/common/npu_addr_pkg.sv",
        ROOT / "rtl/interconnect/npu_data_regfile.sv",
        ROOT / "rtl/interconnect/xbar_stream.sv",
        ROOT / "rtl/interconnect/xbar.sv",
    ]
if a.suite == "sramuncached":
    files = [
        ROOT / "rtl/common/npu_addr_pkg.sv",
        ROOT / "rtl/common/npu_rr_select.sv",
        ROOT / "rtl/interconnect/npu_data_regfile.sv",
        ROOT / "rtl/interconnect/xbar_stream.sv",
        ROOT / "rtl/interconnect/xbar.sv",
        ROOT / "tb/reference_cached_xbar.sv",
    ]
if a.suite == "arbiter":
    files = [ROOT / "rtl/common/npu_rr_select.sv"]
if a.suite == "rfequivalence":
    files = [
        ROOT / "rtl/common/npu_addr_pkg.sv",
        ROOT / "rtl/common/npu_rr_select.sv",
        ROOT / "rtl/interconnect/npu_data_regfile.sv",
        ROOT / "tb/reference_rf_arbiter.sv",
    ]
if a.suite == "readbatch":
    files = [ROOT / "rtl/common/npu_addr_pkg.sv", ROOT / "rtl/interconnect/npu_multi_read.sv"]
if a.suite == "purecompute":
    files = [ROOT / "rtl/matrix/npu_matmul.sv", ROOT / "rtl/vector/npu_vector.sv"]
if a.suite == "cnncompute":
    files = [ROOT / "rtl/cnn/npu_cnn_mac.sv", ROOT / "rtl/cnn/npu_cnn.sv"]
if a.suite == "cnnqueues":
    files = [
        rtl_file(ROOT, f)
        for f in [
            "npu_addr_pkg.sv",
            "npu_stream_pkg.sv",
            "npu_cnn_mac.sv",
            "npu_stream_control.sv",
            "npu_stream_engine.sv",
            "npu_stream.sv",
            "npu_cnn.sv",
        ]
    ]
if a.suite == "vectorprogram":
    files = [
        ROOT / "rtl/common/npu_addr_pkg.sv",
        ROOT / "rtl/vector/npu_vector.sv",
        ROOT / "rtl/vector/npu_vector_stream.sv",
        ROOT / "tb/compute_task_fixtures.sv",
        ROOT / "rtl/matrix/npu_matmul.sv",
        ROOT / "rtl/matrix/npu_matrix_stream.sv",
    ]
if a.suite == "enginefaults":
    files = [
        ROOT / "rtl/matrix/npu_matmul.sv",
        ROOT / "rtl/matrix/npu_matrix_stream.sv",
        ROOT / "rtl/common/npu_addr_pkg.sv",
        ROOT / "rtl/vector/npu_vector.sv",
        ROOT / "rtl/vector/npu_vector_stream.sv",
        ROOT / "tb/compute_task_fixtures.sv",
    ]
if any(f.name in ["npu_matrix_stream.sv", "npu_vector_stream.sv"] for f in files):
    operand_port = ROOT / "rtl/interconnect/npu_multi_read.sv"
    if operand_port not in files:
        files.append(operand_port)
if a.suite == "queues":
    files = [ROOT / "rtl/common/npu_addr_pkg.sv", ROOT / "rtl/control/npu_mmio.sv"]
if any(f.name in ["npu_matrix_stream.sv", "npu_vector_stream.sv"] for f in files):
    pkg = ROOT / "rtl/common/npu_addr_pkg.sv"
    files = [pkg] + [f for f in files if f != pkg]
if a.suite == "xbarstream":
    files = [ROOT / "rtl/common/npu_addr_pkg.sv", ROOT / "rtl/interconnect/xbar_stream.sv"]
if any(f.name in ["npu_data_regfile.sv", "xbar_stream.sv", "xbar.sv"] for f in files):
    helper = ROOT / "rtl/common/npu_rr_select.sv"
    if helper not in files:
        files.append(helper)
if a.macro:
    if a.suite not in [
        "sharedoperands",
        "vectorsimd",
        "ops",
        "jtag",
        "unitroutes",
        "soc",
        "burst",
        "layers",
        "latency",
        "stream",
    ]:
        p.error("macro applies to direct SoC suites")
    macro = (
        ROOT.parent.parent
        / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v"
    )
    text = macro_wrapper((ROOT / "rtl/top/npu_soc.sv").read_text())
    wrapper = out / "npu_soc_macro.sv"
    wrapper.write_text(text)
    files = [f for f in files if f.name not in ["npu_soc.sv", "sram_ff.sv"]] + [wrapper, macro]
cwd = a.artifacts_dir if a.suite in ["jtag", "layers", "latency", "stream"] else out
if a.suite == "soc":
    subprocess.run(["/usr/bin/python3.12", str(ROOT / "sw/gen_boot.py")], check=True)
    shutil.copy2(ROOT / "sw/boot.hex", out / "boot.hex")
assets = (
    list(cwd.glob("*.hex")) if a.suite in ["jtag", "layers", "latency", "stream", "soc"] else []
)
tracked = (
    files
    + [tb]
    + ([ROOT / "tb/db_jtag_tasks.svh"] if a.suite == "jtag" else [])
    + ([ROOT / "tb/mnist_profile.svh"] if a.suite == "latency" else [])
    + list(inc.glob("*"))
    + assets
)
if a.suite in ["latency", "layers", "stream", "jtag"]:
    tracked.append(a.artifacts_dir / "test_meta.svh")
hashes = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked if f.is_file()}
cmd = [
    "vcs",
    "+define+NPU_PARALLEL_UNITS=" + str(a.parallel_units),
    "+define+NPU_RF_BANK_WORDS=" + str(a.rf_bank_words),
    "+define+NPU_CNN_QUEUE_DEPTH=" + str(a.cnn_queue_depth),
    "+define+NPU_MATRIX_QUEUE_DEPTH=" + str(a.matrix_queue_depth),
    "+define+NPU_VECTOR_QUEUE_DEPTH=" + str(a.vector_queue_depth),
    "-full64",
    "-sverilog",
    "-timescale=1ns/1ps",
    "+incdir+" + str(inc),
    "+incdir+" + str(ROOT / "tb"),
    "+incdir+" + str(a.artifacts_dir),
    *map(str, files),
    str(tb),
    "-top",
    top,
    "-o",
    str(out / "simv"),
    "-Mdir=" + str(out / "csrc"),
    "-l",
    str(out / "compile.log"),
]
(out / "command.json").write_text(
    json.dumps(
        {"compile": cmd, "cwd": str(cwd), "macro_functional_timing_checks_disabled": a.macro},
        indent=2,
    )
)
with (out / "compile-launcher.log").open("w") as f:
    r = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT)
if r.returncode:
    raise SystemExit("Compile failed: " + str(out))
cmd = [str(out / "simv"), "-l", str(out / "run.log")]
if a.macro:
    cmd += ["+notimingcheck"]
if a.max_cycles:
    cmd += ["+max_cycles=" + str(a.max_cycles)]
with (out / "run-launcher.log").open("w") as f:
    r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
text = (out / "run.log").read_text()
markers = {
    "sramuncached": "SRAM UNCACHED PASS",
    "arbiter": "ARBITER PASS",
    "rfequivalence": "RF EQUIVALENCE PASS",
    "readbatch": "READ BATCH PASS",
    "sharedoperands": "SHARED OPERANDS PASS",
    "ops": "OPERATORS PASS",
    "jtag": "JTAG PASS",
    "soc": "ALL PASS",
    "xbarstream": "XBAR STREAM PASS",
    "unitroutes": "UNIT ROUTES PASS",
    "xbar": "XBAR ALL PASS",
    "xbarconcurrent": "XBAR CONCURRENT PASS",
    "dma": "PASS",
    "queues": "QUEUES PASS",
    "cnnqueues": "CNN QUEUE PASS",
    "cnncompute": "CNN COMPUTE PASS",
    "purecompute": "PURE COMPUTE PASS",
    "rfsink": "RF SINK PASS",
    "burst": "BURST PASS",
    "layers": "MNIST PASS",
    "latency": "SINGLE PASS",
    "stream": "STREAM PASS",
    "enginefaults": "ENGINE FAULTS PASS",
    "regfile": "REGFILE PASS",
    "vectorprogram": "VECTOR PROGRAM PASS",
    "vectorsimd": "VECTOR SIMD PASS",
}
changed = [
    str(f)
    for f in tracked
    if f.is_file() and hashes[str(f)] != hashlib.sha256(f.read_bytes()).hexdigest()
]
passed = (
    r.returncode == 0
    and markers[a.suite] in text
    and not re.search(r"Fatal:|Error-\[|Warning-\[STASKW|Illegal entry|Not enough words", text)
    and not changed
)
result = {
    "passed": passed,
    "parallel_units": a.parallel_units,
    "suite": a.suite,
    "macro": a.macro,
    "cnn_loop_order": "row",
    "cnn_macs": 9,
    "rf_bank_words": a.rf_bank_words,
    "cnn_queue_depth": a.cnn_queue_depth,
    "matrix_queue_depth": a.matrix_queue_depth,
    "vector_queue_depth": a.vector_queue_depth,
    "max_cycles": a.max_cycles,
    "changed_during_run": changed,
    "sha256": hashes,
    "summaries": [s for s in text.splitlines() if "PASS" in s or s.startswith("SINGLE ")],
}
(out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
for s in result["summaries"][-4:]:
    print(s)
print(out / "result.json")
raise SystemExit(0 if passed else 1)
