"""Freeze open RTL and emit a reproducible Genus run using external TSMC libraries."""

import argparse, hashlib, json, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from sim_sources import macro_wrapper

p = argparse.ArgumentParser()
p.add_argument("--out", type=Path, required=True)
p.add_argument("--pdk", type=Path, default=Path("/home/almalinux/tsmc180"))
p.add_argument(
    "--macro",
    type=Path,
    default=ROOT.parent.parent / "soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8",
)
p.add_argument("--synth-period", type=float, default=16)
p.add_argument("--report-period", type=float, default=20)
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
p.add_argument(
    "--clock-gating", action="store_true", help="Extract library clock gates for enabled registers"
)
p.add_argument(
    "--preserve-unit-boundaries",
    action="store_true",
    help="Keep CPU and accelerator unit hierarchy for area attribution",
)
p.add_argument("--effort", choices=["low", "medium", "high"], default="medium")
a = p.parse_args()
r = a.out.resolve()
r.mkdir(parents=True, exist_ok=False)
(r / "inputs").mkdir()
(r / "reports").mkdir()
subprocess.run(["/usr/bin/python3.12", str(ROOT / "scripts/gen_sources.py")], check=True)
files = [Path(s) for s in (ROOT / "build/asic_sources.f").read_text().splitlines()]
manifest = {}
for f in files:
    rel = f.relative_to(ROOT.parent)
    q = r / "inputs" / rel
    q.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(f, q)
    manifest[str(rel)] = hashlib.sha256(f.read_bytes()).hexdigest()
inc = Path("external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include")
shutil.copytree(ROOT.parent / inc, r / "inputs" / inc, dirs_exist_ok=True)
for f in (ROOT.parent / inc).glob("*"):
    if f.is_file():
        manifest[str(f.relative_to(ROOT.parent))] = hashlib.sha256(f.read_bytes()).hexdigest()
text = macro_wrapper((ROOT / "rtl/top/npu_soc.sv").read_text(), top="npu_asic_top")
(r / "inputs/npu_asic_top.sv").write_text(text)
manifest["npu/rtl/top/npu_soc.sv"] = hashlib.sha256(
    (ROOT / "rtl/top/npu_soc.sv").read_bytes()
).hexdigest()
std = a.pdk / "tcb018gbwp7t_290a/TSMCHOME/digital"
macro = a.macro.resolve()
libs = [
    std / "Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib",
    macro / "RA1SHD_2048x32M8_tt_1p8_25C_syn.lib",
]
lefs = [
    std / "Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef",
    macro / "RA1SHD_2048x32M8.vclef",
    macro / "RA1SHD_2048x32M8_ant.lef",
]
(r / "library_manifest.json").write_text(
    json.dumps({str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in libs + lefs}, indent=2)
    + "\n"
)
(r / "source_manifest.json").write_text(
    json.dumps(
        {
            "git_commit": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip(),
            "branch": subprocess.check_output(
                ["git", "branch", "--show-current"], cwd=ROOT, text=True
            ).strip(),
            "source_root": str(ROOT.parent),
            "source_sha256": manifest,
            "synth_period_ns": a.synth_period,
            "report_period_ns": a.report_period,
            "effort": a.effort,
            "clock_gating": a.clock_gating,
            "local_irq_ids": {"matrix": 16, "vector": 17, "cnn": 18},
            "irq_done_ack_while_active": True,
            "irq_errors_wake_cpu": True,
            "unit_boundaries_preserved": a.preserve_unit_boundaries,
            "sram_banks": 2,
            "rf_bank_words": a.rf_bank_words,
            "cache_words_per_bank": 0,
            "execution_units": ["cnn", "matrix", "vector"],
            "cnn_loop_order": "row",
            "cnn_mac_lanes": 9,
            "planned_pnr_width_um": 2000,
            "planned_pnr_height_um": 2000,
            "cell_area_budget_mm2": 3,
            "cnn_queue_depth": a.cnn_queue_depth,
            "cnn_command_scope": "software-masked tile of one output channel, 1..8 positions",
            "stream_abi": "SD92",
            "stream_task_bits": 43,
            "stream_window_shadow_bits": 32,
            "cnn_kernel_address_per_task": True,
            "cnn_window_words_per_row": 3,
            "shared_gather_slots": 9,
            "matrix_outer_rows": 4,
            "matrix_outer_cols": 4,
            "matrix_products_per_step": 16,
            "matrix_accumulators": 16,
            "matrix_operand_words": 8,
            "matrix_addressing": "incremental validated 15-bit operand offsets",
            "cnn_row_funnel_bits": 48,
            "vector_shared_pack_result_buffer": True,
            "vector_ld32_address_uses_alu": True,
            "matrix_element_precisions": [8, 16],
            "vector_light_lanes": 0,
            "vector_alu_count": 1,
            "shared_quant_units": 1,
            "shared_quant_default": "INT32 bypass",
            "shared_quant_direct_inputs": ["CNN", "Matrix"],
            "vector_simd8_lanes": 4,
            "vector_register_width_bits": 32,
            "vector_program_abi": "VPG2",
            "vector_folded_stages": 0,
            "stream_empty_forwarding": True,
            "arbiter_implementation": "masked-first-set-onehot",
            "rf_decode": "once-per-port",
            "cnn_rf_sink": True,
            "cnn_rf_weight_gather": True,
            "stream_partial_words_in_shared_rf": 8,
            "matrix_queue_depth": a.matrix_queue_depth,
            "vector_queue_depth": a.vector_queue_depth,
            "scope": "Independent CNN GEMM vector units, uncached XBAR CPU JTAG (six ordinary masters + 4x16-word stream channels, no independent DMA) plus two 8KB SRAM macros; excludes PAD/PHY/DDR",
        },
        indent=2,
    )
    + "\n"
)
for name, period in [("synth", a.synth_period), ("report", a.report_period)]:
    (
        r / (name + ".sdc")
    ).write_text(f"""create_clock -name sys_clk -period {period} [get_ports clk_i]
create_clock -name jtag_clk -period 100 [get_ports tck_i]
set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks jtag_clk]
set_clock_uncertainty -setup 0.52 [all_clocks]
set_clock_uncertainty -hold 0.2 [all_clocks]
set_input_delay 0.5 -clock sys_clk [remove_from_collection [all_inputs] [get_ports {{clk_i rst_ni tck_i tms_i td_i}}]]
set_input_delay 0.5 -clock jtag_clk [get_ports {{tms_i td_i}}]
set_output_delay 0.5 -clock sys_clk [remove_from_collection [all_outputs] [get_ports td_o]]
set_output_delay 0.5 -clock jtag_clk -clock_fall [get_ports td_o]
set_input_transition 0.2 [all_inputs]
set_load 0.2 [all_outputs]
set_false_path -from [get_ports rst_ni]
""")


def listing(paths):
    return "{" + " ".join(map(str, paths)) + "}"


preserve_units = (
    """
foreach pattern {*i_cpu *i_xbar *i_mmio *i_stream *i_cnn *i_matmul *i_matrix_stream *i_vector *i_vector_stream *i_quant *i_debug *i_boot} {
 set blocks [get_db hinsts $pattern]
 if {[llength $blocks] == 0} {error "Missing hierarchy: $pattern"}
 set_db $blocks .ungroup_ok false
}
"""
    if a.preserve_unit_boundaries
    else ""
)

tcl = f"""set_db max_cpus_per_server 4
set_db design_process_node 180
set_db init_hdl_search_path {{{r / "inputs" / inc}}}
read_libs {listing(libs)}
read_physical -lef {listing(lefs)}
read_hdl -sv -define {{SYNTHESIS NPU_RF_BANK_WORDS={a.rf_bank_words} NPU_CNN_QUEUE_DEPTH={a.cnn_queue_depth} NPU_MATRIX_QUEUE_DEPTH={a.matrix_queue_depth} NPU_VECTOR_QUEUE_DEPTH={a.vector_queue_depth}}} {listing([r / "inputs" / f.relative_to(ROOT.parent) for f in files] + [r / "inputs/npu_asic_top.sv"])}
{("set_db lp_insert_clock_gating true" + chr(10)) if a.clock_gating else ""}elaborate npu_asic_top
check_design > {r / "reports/elaborated_check.rpt"}
check_design -unresolved > {r / "reports/elaborated_unresolved.rpt"}
read_sdc {r / "synth.sdc"}
set_db syn_generic_effort {a.effort}
set_db syn_map_effort {a.effort}
set_db syn_opt_effort {a.effort}
{preserve_units}syn_generic
report_area > {r / "reports/generic_area.rpt"}
syn_map
report_area > {r / "reports/mapped_area.rpt"}
report_qor > {r / "reports/mapped_qor.rpt"}
write_hdl > {r / "mapped.v"}
syn_opt
report_area > {r / "reports/area.rpt"}
report_qor > {r / "reports/optimized_synth_clock_qor.rpt"}
report_timing -max_paths 10 > {r / "reports/optimized_synth_clock_timing.rpt"}
write_sdc > {r / "optimized_synth_clock.sdc"}
read_sdc {r / "report.sdc"}
report_qor > {r / "reports/qor.rpt"}
report_timing -max_paths 10 > {r / "reports/timing.rpt"}
report_clocks > {r / "reports/clocks.rpt"}
check_design > {r / "reports/check_design.rpt"}
check_design -unresolved > {r / "reports/unresolved.rpt"}
write_hdl > {r / "optimized.v"}
write_sdc > {r / "optimized.sdc"}
write_db -all_root_attributes -to_file {r / "optimized.db"}
puts DUAL_BANK_ASIC_SYNTH_PASS
exit
"""
(r / "synth.tcl").write_text(tcl)
print(r)
