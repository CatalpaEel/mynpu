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
        "irqcontrol",
        "addressranges",
        "sramuncached",
        "arbiter",
        "rfequivalence",
        "readbatch",
        "irqwake",
        "sharedoperands",
        "outergemm",
        "cnnstream",
        "vectorsimd",
        "sharedquant",
        "ops",
        "jtag",
        "quantlayers",
        "soc",
        "xbarstream",
        "unitroutes",
        "xbar",
        "xbarconcurrent",
        "queues",
        "cnnqueues",
        "cnncompute",
        "purecompute",
        "matrixouter",
        "rfsink",
        "burst",
        "layers",
        "blocking",
        "latency",
        "stream",
        "enginefaults",
        "regfile",
        "vectorprogram",
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
    "irqcontrol": "tb_irq_control",
    "irqwake": "tb_irq_wake",
    "addressranges": "tb_address_ranges",
    "sramuncached": "tb_sram_uncached",
    "arbiter": "tb_arbiter",
    "rfequivalence": "tb_rf_equivalence",
    "readbatch": "tb_read_batch",
    "sharedoperands": "tb_shared_operands",
    "ops": "tb_ops",
    "jtag": "tb_jtag",
    "quantlayers": "tb_quant_layers",
    "soc": "tb_npu_soc",
    "xbarstream": "tb_xbar_stream",
    "unitroutes": "tb_unit_routes",
    "xbar": "tb_xbar",
    "xbarconcurrent": "tb_xbar_concurrent",
    "queues": "tb_queues",
    "cnnqueues": "tb_cnn_queue",
    "cnncompute": "tb_cnn_compute",
    "purecompute": "tb_pure_compute",
    "matrixouter": "tb_matrix_outer",
    "outergemm": "tb_outer_gemm",
    "cnnstream": "tb_cnn_stream",
    "rfsink": "tb_rf_sink",
    "burst": "tb_queue_burst",
    "layers": "tb_mnist",
    "blocking": "tb_mnist_blocking",
    "latency": "tb_mnist_latency",
    "stream": "tb_mnist_stream",
    "enginefaults": "tb_engine_faults",
    "regfile": "tb_regfile",
    "vectorprogram": "tb_vector_program",
    "vectorsimd": "tb_vector_simd",
    "sharedquant": "tb_shared_quant",
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
if a.suite == "addressranges":
    files = [ROOT / "rtl/common/npu_addr_pkg.sv"]
if a.suite == "matrixouter":
    files = [ROOT / "rtl/matrix/npu_matmul.sv"]
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
        "irqwake",
        "sharedoperands",
        "outergemm",
        "cnnstream",
        "vectorsimd",
        "sharedquant",
        "ops",
        "jtag",
        "quantlayers",
        "unitroutes",
        "soc",
        "burst",
        "layers",
        "blocking",
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
cwd = (
    a.artifacts_dir
    if a.suite in ["jtag", "quantlayers", "layers", "blocking", "latency", "stream"]
    else out
)
if a.suite == "soc":
    subprocess.run(["/usr/bin/python3.12", str(ROOT / "sw/gen_boot.py")], check=True)
    shutil.copy2(ROOT / "sw/boot.hex", out / "boot.hex")
assets = (
    list(cwd.glob("*.hex"))
    if a.suite in ["jtag", "quantlayers", "layers", "blocking", "latency", "stream", "soc"]
    else []
)
tracked = (
    files
    + [tb]
    + ([ROOT / "tb/db_jtag_tasks.svh"] if a.suite == "jtag" else [])
    + ([ROOT / "tb/mnist_profile.svh"] if a.suite in ["latency", "blocking"] else [])
    + list(inc.glob("*"))
    + assets
)
if a.suite in ["latency", "layers", "stream", "jtag", "quantlayers"]:
    tracked.append(a.artifacts_dir / "test_meta.svh")
if a.suite == "blocking":
    # The dependency-free assembler emits exactly one RV32 word per listing
    # instruction; labels do not consume space. Preserve the binary unchanged.
    import struct

    pc = 32
    classes = [0] * 4096
    labels = {}
    for line in (a.artifacts_dir / "boot.S").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith(":"):
            labels[str(0x80000000 + pc * 4)] = line[:-1]
        else:
            pc += 1
    binary = (a.artifacts_dir / "boot.bin").read_bytes()
    backedges = {}
    for word in range(32, pc):
        insn = struct.unpack_from("<I", binary, word * 4)[0]
        op = insn & 127
        if op == 0x63:
            delta = (
                ((insn >> 31) << 12)
                | (((insn >> 7) & 1) << 11)
                | (((insn >> 25) & 63) << 5)
                | (((insn >> 8) & 15) << 1)
            )
            if delta & 4096:
                delta -= 8192
        elif op == 0x6F:
            delta = (
                ((insn >> 31) << 20)
                | (((insn >> 12) & 255) << 12)
                | (((insn >> 20) & 1) << 11)
                | (((insn >> 21) & 1023) << 1)
            )
            if delta & (1 << 20):
                delta -= 1 << 21
        else:
            continue
        if delta < 0:
            backedges.setdefault(word * 4 + delta, []).append(word)
    ranges = []
    for address, label in labels.items():
        category = (
            1
            if "space" in label
            else 2
            if "drain" in label and "drained" not in label
            else 3
            if re.fullmatch(r"ack[0-9]+", label)
            else 0
        )
        begin = (int(address) - 0x80000000) // 4
        if category and begin * 4 in backedges:
            end = max(backedges[begin * 4]) + 1
            assert end <= pc and end - begin < 128, (label, begin, end)
            classes[begin:end] = [category] * (end - begin)
            ranges.append(
                dict(
                    label=label,
                    start_pc=int(address),
                    end_pc=0x80000000 + end * 4,
                    category=category,
                )
            )
    (out / "block_pc_ranges.json").write_text(json.dumps(ranges, indent=2) + "\n")
    pc_map = out / "block_pc_class.hex"
    pc_map.write_text("".join(f"{c:x}\n" for c in classes))
    (out / "block_pc_labels.json").write_text(json.dumps(labels, indent=2) + "\n")
    tracked += [
        ROOT / "tb/tb_mnist_latency.sv",
        a.artifacts_dir / "boot.S",
        a.artifacts_dir / "boot.bin",
        a.artifacts_dir / "test_meta.svh",
        pc_map,
    ]
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
if a.suite == "blocking":
    cmd.append("+block_pc_map=" + str(pc_map))
if a.macro:
    cmd += ["+notimingcheck"]
if a.max_cycles:
    cmd += ["+max_cycles=" + str(a.max_cycles)]
with (out / "run-launcher.log").open("w") as f:
    r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
text = (out / "run.log").read_text()
markers = {
    "irqcontrol": "IRQ CONTROL PASS",
    "irqwake": "IRQ WAKE PASS",
    "addressranges": "ADDRESS RANGES PASS",
    "sramuncached": "SRAM UNCACHED PASS",
    "arbiter": "ARBITER PASS",
    "rfequivalence": "RF EQUIVALENCE PASS",
    "readbatch": "READ BATCH PASS",
    "sharedoperands": "SHARED OPERANDS PASS",
    "ops": "OPERATORS PASS",
    "jtag": "JTAG PASS",
    "quantlayers": "QUANT LAYERS PASS",
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
    "matrixouter": "MATRIX OUTER PASS",
    "outergemm": "OUTER GEMM PASS",
    "cnnstream": "CNN STREAM PASS",
    "rfsink": "RF SINK PASS",
    "burst": "BURST PASS",
    "layers": "MNIST PASS",
    "blocking": "BLOCKING PASS",
    "latency": "SINGLE PASS",
    "stream": "STREAM PASS",
    "enginefaults": "ENGINE FAULTS PASS",
    "regfile": "REGFILE PASS",
    "vectorprogram": "VECTOR PROGRAM PASS",
    "vectorsimd": "VECTOR SIMD PASS",
    "sharedquant": "SHARED QUANT PASS",
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
