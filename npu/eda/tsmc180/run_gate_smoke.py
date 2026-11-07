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
p.add_argument("--suite", choices=["unitroutes", "cnnstream"], required=True)
a = p.parse_args()
run = a.run.resolve()
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text()
out = run / ("gls-" + a.suite)
out.mkdir(exist_ok=False)
name, marker = {
    "unitroutes": ("tb_unit_routes", "UNIT ROUTES PASS"),
    "cnnstream": ("tb_cnn_stream", "CNN STREAM PASS"),
}[a.suite]
tb = ROOT / "npu/tb" / (name + ".sv")
text = tb.read_text()
assert "dut." not in text
(out / (name + ".sv")).write_text(text.replace("npu_soc dut", "npu_asic_top dut"))
lib = Path(
    "/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital/Front_End/verilog/tcb018gbwp7t_270a/tcb018gbwp7t.v"
)
macro = ROOT.parent / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v"
files = [run / "optimized.v", lib, macro, tb]
hashes = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
cmd = [
    "vcs",
    "-full64",
    "-sverilog",
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
        [str(out / "simv"), "+notimingcheck"], cwd=out, stdout=f, stderr=subprocess.STDOUT
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
print(json.dumps(report, indent=2))
assert passed, out
