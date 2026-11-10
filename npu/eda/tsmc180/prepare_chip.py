"""Freeze a nine-pad chip implementation using the previously proven full flow."""

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
p.add_argument("--core", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument(
    "--remap-core",
    action="store_true",
    help="Experimental: allow remapping of the already mapped core",
)
p.add_argument("--artifacts-dir", type=Path, default=ROOT / "npu/mnist/artifacts")
p.add_argument(
    "--reuse-chip", type=Path, help="Reuse identical mapped shell for a floorplan comparison"
)
a = p.parse_args()
core, run = a.core.resolve(), a.out.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
m = json.loads((core / "source_manifest.json").read_text())
for f, h in m["source_sha256"].items():
    assert sha(resolve_recorded_source(ROOT, f)) == h, f
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (core / "launcher.log").read_text()
run.mkdir(exist_ok=False)
for name in ["scripts", "inputs", "mynpu/chip_synth", "setup"]:
    (run / name).mkdir(parents=True)
old = Path(__file__).with_name("fullchip")
for f in old.glob("*"):
    if f.suffix in [".tcl", ".py"]:
        shutil.copy2(f, run / "scripts" / f.name)
shutil.copy2(core / "optimized.v", run / "inputs/core.v")
shutil.copy2(Path(__file__).with_name("chip_top.sv"), run / "inputs/chip_top.sv")
pdk = Path("/home/almalinux/tsmc180")
std = pdk / "tcb018gbwp7t_290a/TSMCHOME/digital"
macro = ROOT.parent / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8"
(run / "scripts/flow_paths.tcl").write_text(f"set pdk {{{pdk}}}\nset macro {{{macro}}}\n")
# External JTAG timing uses the real 10MHz clock, not the old virtual 1MHz clock.
sdc = """create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports clk_i]
create_clock -name jtag_clk -period 100 -waveform {0 50} [get_ports tck_i]
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks jtag_clk]
set_clock_uncertainty -setup 0.52 [all_clocks]
set_clock_uncertainty -hold 0.2 [all_clocks]
set_input_delay 0.5 -clock sys_clk [get_ports boot_ready_i]
set_output_delay 0.5 -clock sys_clk [get_ports {npu_irq_o cpu_debug_halted_o}]
set_input_delay 0.5 -clock jtag_clk [get_ports {tms_i td_i}]
set_output_delay 0.5 -clock jtag_clk [get_ports td_o]
set_input_transition 0.2 [all_inputs]
set_load 0.2 [all_outputs]
set_false_path -from [get_ports rst_ni]
"""
(run / "scripts/chip.sdc").write_text(sdc)
libs = [
    std / "Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib",
    macro / "RA1SHD_2048x32M8_tt_1p8_25C_syn.lib",
]
lefs = [
    std / "Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef",
    macro / "RA1SHD_2048x32M8.vclef",
    macro / "RA1SHD_2048x32M8_ant.lef",
]
listing = lambda xs: "[list " + " ".join("{" + str(f) + "}" for f in xs) + "]"
out = run / "mynpu/chip_synth"
(run / "scripts/synth_chip.tcl").write_text(f"""set_db max_cpus_per_server 8
set_db design_process_node 180
read_libs {listing(libs)}
read_physical -lef {listing(lefs)}
read_hdl -sv {listing([run / "inputs/core.v", run / "inputs/chip_top.sv"])}
elaborate mynpu_asic_top
{"" if a.remap_core else 'set core_hinst [get_db hinsts *i_soc]; if {[llength $core_hinst] != 1} {error "Expected one mapped core"}; set_db $core_hinst .preserve true'}
read_sdc {{{run / "scripts/chip.sdc"}}}
set_db syn_generic_effort low
set_db syn_map_effort low
set_db syn_opt_effort low
syn_generic
syn_map
syn_opt
write_hdl > {out}/mynpu_asic_top.postsyn.v
write_sdc > {out}/mynpu_asic_top.sdc
report_area > {out}/area.rpt
report_qor > {out}/qor.rpt
report_timing -max_paths 10 > {out}/timing.rpt
check_design > {out}/check_design.rpt
check_design -unresolved > {out}/unresolved.rpt
puts FLOW_STAGE_OK_CHIP_SYNTHESIS
exit
""")
images = run / "inputs/images"
images.mkdir()
image_meta = json.loads((a.artifacts_dir / "model.json").read_text())
assert image_meta["rf_bank_words"] == m["rf_bank_words"], "Firmware/core RF capacity mismatch"
for f in a.artifacts_dir.iterdir():
    if f.is_file() and f.suffix in {".hex", ".bin", ".svh", ".json", ".S"}:
        shutil.copy2(f, images / f.name)
manifest = {
    "core_run": str(core),
    "preserve_original_core_mapping": not a.remap_core,
    "core_manifest_sha256": sha(core / "source_manifest.json"),
    "core_source_manifest": m,
    "scope": f"2mm x 2mm die with native IO/power/corner/filler/bond pads, nine signal pads. Host and external stream pins not bonded; JTAG SBA retained. RF{m['rf_bank_words']} words/bank, M{m['matrix_queue_depth']}/V{m['vector_queue_depth']}/C{m['cnn_queue_depth']}. Generic vector VPG3, LY01 layouts and EV01 task events.",
    "inputs_sha256": {
        str(f.relative_to(run)): sha(f) for f in (run / "inputs").rglob("*") if f.is_file()
    },
    "reference_flow": str(old),
    "reference_sha256": {f.name: sha(f) for f in old.glob("*") if f.suffix in [".tcl", ".py"]},
    "library_sha256": {str(f): sha(f) for f in libs + lefs},
}
io = pdk / "tpd018nv_280a/TSMCHOME/digital"
bond = pdk / "tpb018v_180a/TSMCHOME/digital"
extra = [
    std / "Back_End/lef/tcb018gbwp7t_270a/techfiles/captable/t018lo_1p6m_typical.captable",
    std / "Back_End/lef/tcb018gbwp7t_270a/techfiles/gds2.map",
    std / "Back_End/gds/tcb018gbwp7t_270a/tcb018gbwp7t.gds",
    macro / "RA1SHD_2048x32M8.gds",
    io / "Front_End/timing_power_noise/NLDM/tpd018nv_280a/tpd018nvtc.lib",
    io / "Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/tpd018nv_6lm.lef",
    io / "Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/antenna_6lm.lef",
    io / "Back_End/gds/tpd018nv_280a/mt_2/6lm/tpd018nv.gds",
    bond / "Back_End/lef/tpb018v_180a/cup/6lm/lef/tpb018v_6lm.lef",
    bond / "Back_End/gds/tpb018v_180a/cup/6lm/tpb018v.gds",
]
manifest["library_sha256"].update({str(f): sha(f) for f in extra})
manifest["frozen_script_sha256"] = {
    f.name: sha(f) for f in (run / "scripts").iterdir() if f.is_file()
}
manifest["reference_provenance"] = json.loads((old / "reference.json").read_text())
if a.reuse_chip:
    original = a.reuse_chip.resolve()
    prior = json.loads((original / "manifest.json").read_text())
    assert prior["core_manifest_sha256"] == manifest["core_manifest_sha256"]
    assert prior["library_sha256"] == manifest["library_sha256"]
    for name in ["inputs/core.v", "inputs/chip_top.sv", "scripts/chip.sdc"]:
        assert sha(original / name) == sha(run / name), name
    assert (
        "FLOW_STAGE_OK_CHIP_SYNTHESIS" in (original / "mynpu/chip_synth/launcher.log").read_text()
    )
    source_files = {}
    for f in (original / "mynpu/chip_synth").iterdir():
        if f.is_file():
            shutil.copy2(f, run / "mynpu/chip_synth" / f.name)
            source_files[f.name] = sha(f)
    manifest["reused_chip_synthesis"] = {
        "run": str(original),
        "manifest_sha256": sha(original / "manifest.json"),
        "files_sha256": source_files,
        "scope": "Exact mapped-netlist reuse for independent floorplan trials; copied launcher log records the original execution.",
    }
(run / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(run)
