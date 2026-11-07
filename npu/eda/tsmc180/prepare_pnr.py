"""Freeze a core-only Innovus run from a verified Genus synthesis directory."""

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "npu/scripts"))
from rtl_sources import resolve_recorded_source

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--synth", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
synth, out = a.synth.resolve(), a.out.resolve()
m = json.loads((synth / "source_manifest.json").read_text())
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
for path, digest in m["source_sha256"].items():
    assert sha(resolve_recorded_source(ROOT, path)) == digest, path
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (synth / "launcher.log").read_text()
libs = json.loads((synth / "library_manifest.json").read_text())
for path, digest in libs.items():
    assert sha(path) == digest, path
std = Path("/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital")
cap = std / "Back_End/lef/tcb018gbwp7t_270a/techfiles/captable/t018lo_1p6m_typical.captable"
assert cap.is_file()
out.mkdir(exist_ok=False)
for name in ["reports", "checkpoints", "outputs", "scripts"]:
    (out / name).mkdir()
for src, dest in [
    (synth / "optimized.v", "netlist.v"),
    (synth / "report.sdc", "constraints.sdc"),
    (Path(__file__).with_name("pnr.tcl"), "scripts/pnr.tcl"),
    (Path(__file__).with_name("pnr_capture.tcl"), "scripts/pnr_capture.tcl"),
    (Path(__file__).with_name("fix_pg_edge_vias.tcl"), "scripts/fix_pg_edge_vias.tcl"),
]:
    shutil.copy2(src, out / dest)
libpaths = [x for x in libs if x.endswith(".lib")]
lefpaths = [x for x in libs if x.endswith((".lef", ".vclef"))]
fmt = lambda xs: " ".join("{" + str(x) + "}" for x in xs)
(
    out / "scripts/mmmc.tcl"
).write_text(f"""create_library_set -name lib_tt -timing [list {fmt(libpaths)}]
create_rc_corner -name rc_tt -T 25 -cap_table {{{cap}}}
create_delay_corner -name delay_tt -library_set lib_tt -rc_corner rc_tt
create_constraint_mode -name func -sdc_files {{{out / "constraints.sdc"}}}
create_analysis_view -name func_tt -constraint_mode func -delay_corner delay_tt
set_analysis_view -setup func_tt -hold func_tt
""")
(out / "scripts/paths.tcl").write_text(f"set out {{{out}}}\nset lefs [list {fmt(lefpaths)}]\n")
files = [out / "netlist.v", out / "constraints.sdc", *list((out / "scripts").glob("*.tcl"))]
manifest = {
    "synthesis": str(synth),
    "synthesis_manifest_sha256": sha(synth / "source_manifest.json"),
    "build": m,
    "scope": "2mm x 2mm core-only die, 20um margins, real two SRAM macros, no pads; TT exploratory PnR, not signoff",
    "input_sha256": {str(f): sha(f) for f in files},
    "library_sha256": {**libs, str(cap): sha(cap)},
}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(out)
