"""Real-CPU functional checks on mapped or routed ASIC netlists, no SDF."""

import argparse, hashlib, json, re, subprocess, sys
from pathlib import Path
from rtl_sources import resolve_recorded_source

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent / "tools"))
from format_code import tool

p = argparse.ArgumentParser()
p.add_argument(
    "--suite", choices=["latency", "jtag", "ops", "burst", "units", "layout"], default="latency"
)
p.add_argument("--run", required=True, type=Path)
p.add_argument("--tag", required=True)
p.add_argument("--netlist", type=Path, help="Use an explicitly selected routed netlist")
p.add_argument("--max-cycles", type=int, default=0)
p.add_argument("--samples", type=int, default=1)
p.add_argument(
    "--format-baseline",
    type=Path,
    help="Allow only token-identical formatting against frozen source",
)
p.add_argument("--artifacts-dir", type=Path, default=ROOT / "mnist/artifacts")
a = p.parse_args()
a.artifacts_dir = a.artifacts_dir.resolve()
assert re.fullmatch(r"[A-Za-z0-9_-]+", a.tag) and 1 <= a.samples <= 10
run = a.run.resolve()
manifest = json.loads((run / "source_manifest.json").read_text())
format_equivalence = {}
for f, h in manifest["source_sha256"].items():
    current = resolve_recorded_source(ROOT.parent, f)
    current_hash = hashlib.sha256(current.read_bytes()).hexdigest()
    if current_hash == h:
        continue
    assert a.format_baseline is not None and current.suffix in {".sv", ".svh"}, f
    candidates = [run / "inputs" / f, a.format_baseline.resolve() / f]
    original = next(
        (p for p in candidates if p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == h),
        None,
    )
    assert original is not None, f"No matching frozen source: {f}"
    subprocess.run(
        [tool("verible-verilog-diff"), "--mode=format", str(original), str(current)], check=True
    )
    format_equivalence[f] = {
        "original_sha256": h,
        "current_sha256": current_hash,
        "frozen_source": str(original),
        "tokens_identical": True,
    }
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text()
out = ROOT / "build" / ("gate-" + a.tag)
out.mkdir(parents=True, exist_ok=False)
testbench = {
    "latency": "tb_mnist_latency",
    "units": "tb_netlist_units",
    "layout": "tb_layout_events",
    "jtag": "tb_jtag",
    "ops": "tb_ops",
    "burst": "tb_queue_burst",
}[a.suite]
text = (ROOT / "tb" / (testbench + ".sv")).read_text()
text, count = re.subn(r"\bnpu_soc\s+dut\b", "npu_asic_top dut", text)
assert count == 1, "Expected one SoC DUT"
for old, new in [
    ("SINGLE PASS", "GATE PASS"),
    ("UNIT SMOKE PASS", "GATE UNIT SMOKE PASS"),
    ("LAYOUT EVENTS PASS", "GATE LAYOUT EVENTS PASS"),
    ("SINGLE_INPUT", "GATE_INPUT"),
    ("OPERATORS PASS", "GATE OPERATORS PASS"),
    ("BURST PASS", "GATE BURST PASS"),
    ("JTAG PASS", "GATE JTAG PASS"),
]:
    text = text.replace(old, new)
observer_aliases = {}
(out / "tb_gate.sv").write_text(text)
std = Path(
    "/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital/Front_End/verilog/tcb018gbwp7t_270a/tcb018gbwp7t.v"
)
macro = (
    ROOT.parent.parent
    / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v"
)
files = [a.netlist.resolve() if a.netlist else run / "optimized.v", std, macro, out / "tb_gate.sv"]
assets = list(a.artifacts_dir.glob("*.hex")) + (
    [ROOT / "tb/db_jtag_tasks.svh"] if a.suite == "jtag" else []
)
assets.append(a.artifacts_dir / "test_meta.svh")
hashes = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files + assets}
cmd = [
    "vcs",
    "+define+NPU_GATE_SIM",
    "-full64",
    "-sverilog",
    "-timescale=1ns/1ps",
    "+delay_mode_zero",
    "+incdir+" + str(a.artifacts_dir),
    "+incdir+" + str(ROOT / "tb"),
    *map(str, files),
    "-top",
    {
        "jtag": "tb_jtag",
        "ops": "tb_ops",
        "latency": "tb_mnist_latency",
        "burst": "tb_queue_burst",
        "units": "tb_netlist_units",
        "layout": "tb_layout_events",
    }[a.suite],
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
            "scope": "Mapped netlist plus actual library/macro functional models; zero delay, no SDF, timing checks disabled",
        },
        indent=2,
    )
)
with (out / "compile-launcher.log").open("w") as f:
    r = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT)
if r.returncode:
    raise SystemExit("Compile failed: " + str(out))
with (out / "run-launcher.log").open("w") as f:
    r = subprocess.run(
        [
            str(out / "simv"),
            "+samples=" + str(a.samples),
            "+notimingcheck",
            "+max_cycles=" + str(a.max_cycles),
            "-l",
            str(out / "run.log"),
        ],
        cwd=a.artifacts_dir,
        stdout=f,
        stderr=subprocess.STDOUT,
    )
log = (out / "run.log").read_text()
changed = [s for s, h in hashes.items() if hashlib.sha256(Path(s).read_bytes()).hexdigest() != h]
marker = {
    "jtag": "GATE JTAG PASS",
    "ops": "GATE OPERATORS PASS",
    "burst": "GATE BURST PASS",
    "latency": f"GATE PASS samples={a.samples}",
    "units": "GATE UNIT SMOKE PASS",
    "layout": "GATE LAYOUT EVENTS PASS",
}[a.suite]
passed = (
    r.returncode == 0
    and marker in log
    and not re.search(r"Fatal:|Error-\[|Warning-\[STASKW", log)
    and not changed
)
j = {
    "passed": passed,
    "suite": a.suite,
    "samples": a.samples,
    "zero_delay": True,
    "observer_signal_aliases": observer_aliases,
    "removed_page_error_probe": "external host error response" if a.suite == "jtag" else None,
    "format_only_source_equivalence": format_equivalence,
    "sdf": False,
    "timing_checks_disabled": True,
    "changed_during_run": changed,
    "sha256": hashes,
    "summaries": [s for s in log.splitlines() if "PASS" in s],
}
(out / "result.json").write_text(json.dumps(j, indent=2) + "\n")
print("\n".join(j["summaries"]))
print(out / "result.json")
raise SystemExit(0 if passed else 1)
