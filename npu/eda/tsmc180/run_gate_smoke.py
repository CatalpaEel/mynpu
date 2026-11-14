"""Run port-only compute/route regressions on an exact mapped ASIC netlist."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--suite", choices=["unitroutes", "cnnstream", "latency"], required=True)
p.add_argument("--artifacts-dir", type=Path, default=ROOT / "npu/mnist/artifacts")
p.add_argument("--tag", default="")
a = p.parse_args()
run = a.run.resolve()
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text()
out = run / ("gls-" + a.suite + ("-" + a.tag if a.tag else ""))
out.mkdir(exist_ok=False)
name, marker = {
    "unitroutes": ("tb_unit_routes", "UNIT ROUTES PASS"),
    "cnnstream": ("tb_cnn_stream", "CNN STREAM PASS"),
    "latency": ("tb_mnist_latency", "SINGLE PASS"),
}[a.suite]
tb = ROOT / "npu/tb" / (name + ".sv")
text = tb.read_text()
assert a.suite == "latency" or "dut." not in text
(out / (name + ".sv")).write_text(text.replace("npu_soc dut", "npu_asic_top dut"))
lib = Path(
    "/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital/Front_End/verilog/tcb018gbwp7t_270a/tcb018gbwp7t.v"
)
macro = ROOT.parent / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v"
assets = (
    list(a.artifacts_dir.resolve().glob("*.hex")) + [a.artifacts_dir.resolve() / "test_meta.svh"]
    if a.suite == "latency"
    else []
)
files = [run / "optimized.v", lib, macro, tb, ROOT / "npu/tb/db_jtag_tasks.svh", ROOT / "npu/tb/db_sba_access.svh"] + assets
hashes = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
cmd = [
    "vcs",
    "-full64",
    "-sverilog",
    "+define+NPU_GATE_SIM",
    "+incdir+" + str(a.artifacts_dir.resolve()),
    "+incdir+" + str(ROOT / "npu/tb"),
    "+nospecify",
    "+notimingcheck",
    "+delay_mode_zero",
    "-timescale=1ns/1ps",
    str(run / "optimized.v"),
    str(lib),
    str(macro),
    str(out / (name + ".sv")),
    "-top",
    name,
    "-o",
    str(out / "simv"),
    "-Mdir=" + str(out / "csrc"),
]
(out / "command.json").write_text(json.dumps(cmd, indent=2) + "\n")
with (out / "compile.log").open("w") as f:
    r = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT)
assert r.returncode == 0, out
with (out / "run.log").open("w") as f:
    r = subprocess.run(
        [str(out / "simv"), "+notimingcheck", "+samples=1"],
        cwd=a.artifacts_dir.resolve() if a.suite == "latency" else out,
        stdout=f,
        stderr=subprocess.STDOUT,
    )
log = (out / "run.log").read_text()
passed = r.returncode == 0 and marker in log and not re.search(r"Fatal:|Error-\[", log)
assert hashes == {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
report = dict(
    passed=passed,
    scope="Zero-delay gate-level functional smoke; no SDF, no physical timing signoff",
    suite=a.suite,
    sha256=hashes,
    summaries=[l for l in log.splitlines() if "PASS" in l],
)
(out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "sha256"}, indent=2))
assert passed, out
