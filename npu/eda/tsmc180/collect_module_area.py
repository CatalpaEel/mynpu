"""Collect disjoint functional buckets from a hierarchical Genus area report."""

import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--run", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
run = args.run.resolve()
rows = []
for line in (run / "reports/area.rpt").read_text().splitlines():
    match = re.match(r"^( *)(\S+)\s+(?:(\S+)\s+)?(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$", line)
    if match:
        rows.append(
            dict(
                indent=len(match[1]),
                instance=match[2],
                module=match[3],
                cells=int(match[4]),
                area_um2=float(match[5]),
            )
        )
assert rows and rows[0]["instance"] == "npu_asic_top", "Unexpected report hierarchy"
total = rows[0]["area_um2"]
core = next((row for row in rows if row["instance"] == "i_core" and row["indent"] == 2), None)
children = [row for row in rows if row["indent"] == (4 if core else 2)]
buckets = {}
for row in children:
    name = row["instance"]
    if name.startswith("i_core_"):
        name = name[len("i_core_") :]
    if name.startswith("i_cpu"):
        group = "CPU"
    elif name.startswith("i_xbar"):
        group = "XBAR"
    elif name.startswith("i_mmio"):
        group = "MMIO / task queues"
    elif name.startswith("i_quant"):
        group = "Shared quantizer"
    elif name.startswith(("i_vector",)):
        group = "Vector"
    elif name.startswith(("i_matrix", "i_matmul")):
        group = "Matrix"
    elif name.startswith(("i_stream", "i_cnn")):
        group = "CNN"
    elif name.startswith(("i_debug", "i_boot")):
        group = "JTAG / debug"
    else:
        group = "Other named modules"
    buckets.setdefault(group, {"area_um2": 0, "instances": []})
    buckets[group]["area_um2"] += row["area_um2"]
    buckets[group]["instances"].append(row)
# Hierarchical report excludes hard macros as rows. Derive their area from the
# top/core difference; keep top-level standard cells explicitly separated.
netlist = (run / "optimized.v").read_text()
macro_count = len(re.findall(r"\bRA1SHD_2048x32M8\s+(?:\\\S+|\w+)\s*\(", netlist))
manifest = json.loads((run / "library_manifest.json").read_text())
# The frozen wrapper explicitly instantiates exactly two identical SRAM macros.
macro_libraries = [Path(name) for name in manifest if name.endswith(".lib") and "RA1SHD" in name]
if not macro_libraries:
    # Older manifests may use a list or contain logical names; locate via script.
    macro_libraries = [
        Path(p) for p in re.findall(r"[^\s{}]+RA1SHD[^\s{}]+\.lib", (run / "synth.tcl").read_text())
    ]
assert macro_count == 2 and len(macro_libraries) == 1, (macro_count, macro_libraries)
lib = macro_libraries[0].read_text()
cell = (
    lib[lib.index("cell (RA1SHD_2048x32M8") :]
    if "cell (RA1SHD_2048x32M8" in lib
    else lib[lib.index("cell(") :]
)
macro_area = float(re.search(r"\barea\s*:\s*([\d.]+)", cell)[1]) * macro_count
buckets["SRAM macros"] = {"area_um2": macro_area, "count": macro_count}
glue = (
    total
    - macro_area
    - sum(item["area_um2"] for name, item in buckets.items() if name != "SRAM macros")
)
assert glue >= -0.01, glue
buckets["Top / core glue"] = {"area_um2": max(0, glue)}
for bucket in buckets.values():
    bucket["area_mm2"] = bucket["area_um2"] / 1e6
    bucket["percent_total"] = bucket["area_um2"] / total * 100
assert abs(sum(b["area_um2"] for b in buckets.values()) - total) < 0.02
xbar_total = buckets.get("XBAR", {}).get("area_um2", 0)
rf_area = sum(
    row["area_um2"]
    for row in rows
    if row["indent"] == (6 if core else 4) and row["instance"] == "i_regfile"
)
fifo_area = sum(
    row["area_um2"]
    for row in rows
    if row["indent"] == (6 if core else 4) and row["instance"] == "i_stream_routes"
)
source_settings = json.loads((run / "source_manifest.json").read_text())
cache_words = source_settings.get("cache_words_per_bank", 16)
remaining_name = (
    "sram_read_cache_and_arbitration_mm2" if cache_words else "sram_arbitration_and_response_mm2"
)
xbar_breakdown = {
    "shared_rf_mm2": rf_area / 1e6,
    "stream_fifo_mm2": fifo_area / 1e6,
    remaining_name: (xbar_total - rf_area - fifo_area) / 1e6,
}

report = {
    "run": str(run),
    "scope": "mapped cell area, two SRAM macros included, PADs and PNR overhead excluded",
    "total_area_mm2": total / 1e6,
    "standard_cell_area_mm2": (total - macro_area) / 1e6,
    "buckets": buckets,
    "hierarchical_rows": rows,
    "xbar_breakdown": xbar_breakdown,
    "sram_cache_words_per_bank": cache_words,
    "compute_boundaries_preserved": ".ungroup_ok false" in (run / "synth.tcl").read_text(),
}
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(json.dumps(report, indent=2) + "\n")
print("Total cell area: %.6f mm2" % (total / 1e6))
for name, bucket in sorted(buckets.items(), key=lambda item: -item[1]["area_um2"]):
    print("%-23s %.6f mm2 %5.2f%%" % (name, bucket["area_mm2"], bucket["percent_total"]))
