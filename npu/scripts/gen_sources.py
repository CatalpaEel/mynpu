from pathlib import Path
from rtl_sources import project_sources
import os, json


def atomic_write(path, text):
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    try:
        temporary.write_text(text)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


root = Path(__file__).resolve().parents[1]
(root / "build").mkdir(parents=True, exist_ok=True)
external = root.parent / "external/lab3-ST/SoC_cv32e40p"
cpu = external / "cpu_cv32e40p"
files = [
    cpu / "include" / p
    for p in ["cv32e40p_pkg.sv", "cv32e40p_apu_core_pkg.sv", "cv32e40p_fpu_pkg.sv"]
]
soc = external / "soc/rtl"
files += [soc / "common_cells/cf_math_pkg.sv", soc / "debug/dm_pkg.sv"]
files += [
    soc / p
    for p in [
        "clk_rst/tc_clk.sv",
        "clk_rst/pulp_clk_cells.sv",
        "clk_rst/cluster_clk_cells.sv",
        "common_cells/fifo_v3.sv",
        "common_cells/fifo_v2.sv",
        "common_cells/cdc_2phase.sv",
        "clk_rst/rstgen_bypass.sv",
        "clk_rst/rstgen.sv",
        "debug/debug_rom.sv",
        "debug/dm_csrs.sv",
        "debug/dm_mem.sv",
        "debug/dm_sba.sv",
        "debug/dm_top.sv",
        "debug/dmi_cdc.sv",
        "debug/dmi_jtag_tap.sv",
        "debug/dmi_jtag.sv",
    ]
]
files += [external / "soc/rtl/mem/sram_ff.sv"]
files += sorted(p for p in (cpu / "rtl").glob("*.sv") if p.name != "cv32e40p_fp_wrapper.sv")
project_rtl = project_sources(root)
files += [p for p in project_rtl if p.name.endswith("_pkg.sv")]
files += [p for p in project_rtl if not p.name.endswith("_pkg.sv")]
atomic_write(root / "build/sources.f", "\n".join(map(str, files)) + "\n")
atomic_write(
    root / "build/sources.tcl",
    "set npu_defines {NPU_RF_BANK_WORDS="
    + str(json.loads((root / "build_config.json").read_text())["rf_bank_words"])
    + " NPU_MATRIX_QUEUE_DEPTH="
    + str(json.loads((root / "build_config.json").read_text())["matrix_queue_depth"])
    + " NPU_VECTOR_QUEUE_DEPTH="
    + str(json.loads((root / "build_config.json").read_text())["vector_queue_depth"])
    + " NPU_CNN_QUEUE_DEPTH="
    + str(json.loads((root / "build_config.json").read_text())["cnn_queue_depth"])
    + " NPU_STREAM_FIFO_DEPTH="
    + str(json.loads((root / "build_config.json").read_text())["stream_fifo_depth"])
    + "}\nset npu_sources {\n"
    + "".join("  {" + str(p) + "}\n" for p in files)
    + "}\n",
)
print(len(files), "SystemVerilog sources")
atomic_write(
    root / "build/asic_sources.f",
    "\n".join(str(p) for p in files if p.name not in ["sram_ff.sv", "npu_soc.sv"]) + "\n",
)
