"""Render actual Innovus-exported cell rectangles with a hierarchy legend."""

import argparse
import csv
import hashlib
import html
import json
from collections import Counter
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
source = a.run / "chip/module_instances.tsv"
rows = list(csv.DictReader(source.open(), delimiter="\t"))
assert len(rows) > 80000, "Incomplete instance export"
colors = {}
counts = Counter()
area = Counter()
rectangles = []
seen = set()
for r in rows:
    assert r["name"] not in seen, r["name"]
    seen.add(r["name"])
    group, color = r["group"], r["color"]
    if "/i_xbar/i_regfile/" in r["name"]:
        group, color = "Shared_RF", "#fde68a"
    x0, y0, x1, y1 = (float(r[k]) for k in ["x0", "y0", "x1", "y1"])
    colors[group] = color
    counts[group] += 1
    area[group] += (x1 - x0) * (y1 - y0)
    rectangles.append(
        f'<rect x="{x0}" y="{2000 - y1}" width="{x1 - x0}" height="{y1 - y0}" fill="{color}"/>'
    )
labels = {
    "CPU": "CPU",
    "XBAR": "XBAR / SRAM cache",
    "Shared_RF": "Shared RF (256 B)",
    "CNN": "CNN compute",
    "CNN_Stream": "CNN Stream / windows",
    "Matrix": "Matrix compute",
    "Matrix_Stream": "Matrix Stream",
    "Vector": "Vector ALU",
    "Vector_Issue": "Vector Issue / registers",
    "MMIO": "MMIO / queues / dependencies",
    "Debug_DMA": "Debug / boot / DMA",
    "SRAM": "Two SRAM macros",
    "Other": "Other / physical support",
}
svg = [
    '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1240" viewBox="0 0 2700 2100">',
    '<rect width="2700" height="2100" fill="#111827"/>',
    '<text x="40" y="48" fill="white" font-size="30" font-family="sans-serif">Final routed design: actual instance locations by hierarchy</text>',
    '<g transform="translate(40 80)">',
    '<rect width="2000" height="2000" fill="#263244" stroke="#cbd5e1" stroke-width="2"/>',
    '<rect x="130.48" y="130.16" width="1739.36" height="1740.48" fill="#080d16"/>',
    *rectangles,
    "</g>",
]
for i, group in enumerate(labels):
    if group not in counts:
        continue
    y = 115 + i * 117
    svg += [
        f'<rect x="2100" y="{y}" width="30" height="30" fill="{colors[group]}"/>',
        f'<text x="2145" y="{y + 25}" fill="white" font-size="25" font-family="sans-serif">{html.escape(labels[group])}</text>',
        f'<text x="2145" y="{y + 59}" fill="#cbd5e1" font-size="21" font-family="sans-serif">{counts[group]:,} cells / {area[group] / 1e6:.6f} mm²</text>',
    ]
svg += [
    '<text x="2100" y="1770" fill="#cbd5e1" font-size="22" font-family="sans-serif">Die: 2000 x 2000 um</text>',
    '<text x="2100" y="1820" fill="#cbd5e1" font-size="21" font-family="sans-serif">Grey ring: IO region (schematic)</text>',
    '<text x="2100" y="1870" fill="#cbd5e1" font-size="21" font-family="sans-serif">Routing omitted; fillers shown in grey.</text>',
    '<text x="2100" y="1920" fill="#cbd5e1" font-size="21" font-family="sans-serif">Other includes fillers / clock support.</text>',
    "</svg>",
]
a.out.write_text("\n".join(svg))
files = [
    source,
    a.run / "chip/scripts/module_map.tcl",
    a.run / "module-map.log",
    a.run / "chip/mynpu/pnr/checkpoints/13_finished.enc",
    a.out,
]
a.out.with_suffix(".source.json").write_text(
    json.dumps(
        dict(
            scope="Actual final placed instance rectangles exported by Innovus; IO region background is schematic; no route rendering; fillers in Other",
            groups={
                g: dict(cells=counts[g], bbox_sum_area_mm2=area[g] / 1e6, color=colors[g])
                for g in counts
            },
            sha256={str(f.resolve()): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        ),
        indent=2,
    )
    + "\n"
)
print(json.dumps(dict(cells=len(rows), groups=counts), indent=2))
