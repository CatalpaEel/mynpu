"""Exercise the nine-signal chip through JTAG only, including SBA-loaded MNIST."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--tag", required=True)
p.add_argument("--netlist", type=Path)
p.add_argument("--shell", action="store_true", help="Check the mapped core plus frozen RTL shell")
p.add_argument("--artifacts-dir", type=Path)
a = p.parse_args()
assert re.fullmatch("[A-Za-z0-9_-]+", a.tag)
r = a.run.resolve()
manifest = json.loads((r / "manifest.json").read_text())
rf_words = manifest["core_source_manifest"]["rf_bank_words"]
images = (
    a.artifacts_dir.resolve()
    if a.artifacts_dir
    else (r / "inputs/images" if (r / "inputs/images").exists() else ROOT / "mnist/artifacts")
)
out = ROOT / "build" / ("chip-" + a.tag)
out.mkdir(exist_ok=False)
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
files = (
    [r / "inputs/core.v", r / "inputs/chip_top.sv"]
    if a.shell
    else [a.netlist.resolve() if a.netlist else r / "mynpu/chip_synth/mynpu_asic_top.postsyn.v"]
)
std = Path(
    "/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital/Front_End/verilog/tcb018gbwp7t_270a/tcb018gbwp7t.v"
)
io = Path(
    "/home/almalinux/tsmc180/tpd018nv_280a/TSMCHOME/digital/Front_End/verilog/tpd018nv_260a/tpd018nv.v"
)
macro = (
    ROOT.parent.parent
    / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v"
)
helper = ROOT / "tb/db_jtag_tasks.svh"
# 10MHz pin clock matches physical constraints; preserve the shared helper.
(out / "db_jtag_tasks.svh").write_text(helper.read_text().replace("#20;", "#50;"))
files += [std, io, macro, ROOT / "tb/tb_chip_jtag.sv"]
assets = [helper, out / "db_jtag_tasks.svh", *list(images.glob("*.hex"))]
hashes = {str(f): sha(f) for f in files + assets}
cmd = [
    "vcs",
    "+define+NPU_CHIP_RF_BANK_WORDS=" + str(rf_words),
    "-full64",
    "-sverilog",
    "-timescale=1ns/1ps",
    "+delay_mode_zero",
    "+incdir+" + str(out),
    *map(str, files),
    "-top",
    "tb_chip_jtag",
    "-o",
    str(out / "simv"),
    "-Mdir=" + str(out / "csrc"),
    "-l",
    str(out / "compile.log"),
]
(out / "command.json").write_text(
    json.dumps(
        {
            "compile": cmd,
            "scope": "Native nine external signals only, JTAG at 10MHz; actual library and SRAM models; zero delay, no SDF.",
        },
        indent=2,
    )
    + "\n"
)
with (out / "compile-launcher.log").open("w") as f:
    rc = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT).returncode
assert rc == 0, "Compile failed: " + str(out)
with (out / "run-launcher.log").open("w") as f:
    rc = subprocess.run(
        [str(out / "simv"), "+notimingcheck", "-l", str(out / "run.log")],
        cwd=images,
        stdout=f,
        stderr=subprocess.STDOUT,
    ).returncode
text = (out / "run.log").read_text()
changed = [name for name, h in hashes.items() if sha(name) != h]
passed = (
    rc == 0
    and "CHIP JTAG PASS" in text
    and not re.search("Fatal:|Error-\\[|Warning-\\[STASKW", text)
    and not changed
)
j = {
    "passed": passed,
    "shell": a.shell,
    "sha256": hashes,
    "changed_during_run": changed,
    "jtag_mhz": 10,
    "sdf": False,
    "summaries": [line for line in text.splitlines() if "PASS" in line],
}
(out / "result.json").write_text(json.dumps(j, indent=2) + "\n")
print(json.dumps({k: v for k, v in j.items() if k != "sha256"}, indent=2), flush=True)
raise SystemExit(0 if passed else 1)
