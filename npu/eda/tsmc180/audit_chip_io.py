"""Check native IO packing separately from intentional bond-window overlap."""

import argparse
import hashlib
import json
import re
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--def", dest="design", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
lefs = [
    Path(
        "/home/almalinux/tsmc180/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/tpd018nv_6lm.lef"
    ),
    Path(
        "/home/almalinux/tsmc180/tpb018v_180a/TSMCHOME/digital/Back_End/lef/tpb018v_180a/cup/6lm/lef/tpb018v_6lm.lef"
    ),
]
sizes = {}
for f in lefs:
    for match in re.finditer(r"^MACRO\s+(\S+)(.*?)(?=^MACRO|\Z)", f.read_text(), re.M | re.S):
        size = re.search(r"\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)", match[2])
        if size:
            sizes[match[1]] = tuple(map(float, size.groups()))
text = a.design.read_text()
unit = int(re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", text)[1])
body = text.split("COMPONENTS ", 1)[1].split("END COMPONENTS", 1)[0]
native = []
bonds = []
for match in re.finditer(r"^-\s+(\S+)\s+(\S+)(.*?);", body, re.M | re.S):
    name, cell, detail = match.groups()
    if not name.startswith(("i_pad_", "IOF_", "corner_", "bond_")):
        continue
    assert cell in sizes, (name, cell)
    pos = re.search(r"\+\s+(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", detail)
    assert pos, name
    x, y = float(pos[1]) / unit, float(pos[2]) / unit
    orientation = pos[3]
    width, height = sizes[cell]
    if orientation in ["E", "W", "FE", "FW"]:
        width, height = height, width
    row = {
        "name": name,
        "cell": cell,
        "box": [x, y, x + width, y + height],
        "orientation": orientation,
    }
    (bonds if name.startswith("bond_") else native).append(row)


def intersection(a, b):
    return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))


overlap = []
for i, row in enumerate(native):
    for other in native[i + 1 :]:
        area = intersection(row["box"], other["box"])
        if area > 0.001:
            overlap.append([row["name"], other["name"], area])
assert not overlap, overlap[:10]
assert sum(row["cell"] == "PDDW0204CDG" for row in native) == 9
assert sum(row["cell"] == "PCORNER" for row in native) == 4
assert len([row for row in native if row["name"].startswith("i_pad_")]) == 37
assert len(bonds) == 37
for row in native + bonds:
    x0, y0, x1, y1 = row["box"]
    assert x0 >= -0.001 and y0 >= -0.001 and x1 <= 2000.001 and y1 <= 2000.001, row
parents = {row["name"]: row for row in native}
for row in bonds:
    assert intersection(row["box"], parents[row["name"].removeprefix("bond_")]["box"]) > 0, row
sides = {side: [] for side in ["top", "bottom", "left", "right"]}
for row in native:
    if row["cell"] == "PCORNER":
        continue
    x0, y0, x1, y1 = row["box"]
    if abs(y0) < 0.001:
        side, lo, hi = "bottom", x0, x1
    elif abs(y1 - 2000) < 0.001:
        side, lo, hi = "top", x0, x1
    elif abs(x0) < 0.001:
        side, lo, hi = "left", y0, y1
    elif abs(x1 - 2000) < 0.001:
        side, lo, hi = "right", y0, y1
    else:
        raise AssertionError(row)
    sides[side].append((lo, hi, row["name"]))
for side, rows in sides.items():
    rows.sort()
    last = 115.0
    for lo, hi, name in rows:
        assert abs(lo - last) <= 0.001, (side, name, lo, last)
        last = hi
    assert abs(last - 1885) <= 0.001, (side, last)
area = (
    sum((row["box"][2] - row["box"][0]) * (row["box"][3] - row["box"][1]) for row in native) / 1e6
)
# External signal labels must land in the native PAD terminal, rather than
# on an adjacent filler. The METAL4 PAD terminal is 55um wide by 5.6um deep.
pin_section = text.split("\nPINS ", 1)[1].split("END PINS", 1)[0]
orientation_matrix = {
    "N": (1, 0, 0, 1),
    "S": (-1, 0, 0, -1),
    "W": (0, -1, 1, 0),
    "E": (0, 1, -1, 0),
    "FN": (-1, 0, 0, 1),
    "FS": (1, 0, 0, -1),
    "FW": (0, -1, -1, 0),
    "FE": (0, 1, 1, 0),
}
pin_landings = []
for row in native:
    if row["cell"] != "PDDW0204CDG":
        continue
    port = row["name"].removeprefix("i_pad_")
    record = re.search(r"^-\s+" + re.escape(port) + r"\s+.*?;", pin_section, re.M | re.S)
    assert record, port
    rectangle = re.search(
        r"LAYER\s+METAL4\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", record[0]
    )
    location = re.search(r"(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", record[0])
    assert rectangle and location, port
    dx0, dy0, dx1, dy1 = (int(v) / unit for v in rectangle.groups())
    px, py = int(location[1]) / unit, int(location[2]) / unit
    aa, bb, cc, dd = orientation_matrix[location[3]]
    coords = [
        (px + aa * x + bb * y, py + cc * x + dd * y)
        for x, y in [(dx0, dy0), (dx0, dy1), (dx1, dy0), (dx1, dy1)]
    ]
    box = [
        min(x for x, y in coords),
        min(y for x, y in coords),
        max(x for x, y in coords),
        max(y for x, y in coords),
    ]
    x0, y0, x1, y1 = row["box"]
    if abs(y0) < 0.001:
        terminal = [x0 + 2.5, 0, x1 - 2.5, 5.6]
    elif abs(y1 - 2000) < 0.001:
        terminal = [x0 + 2.5, 1994.4, x1 - 2.5, 2000]
    elif abs(x0) < 0.001:
        terminal = [0, y0 + 2.5, 5.6, y1 - 2.5]
    else:
        terminal = [1994.4, y0 + 2.5, 2000, y1 - 2.5]
    assert all(
        [
            box[0] >= terminal[0] - 0.001,
            box[1] >= terminal[1] - 0.001,
            box[2] <= terminal[2] + 0.001,
            box[3] <= terminal[3] + 0.001,
        ]
    ), (port, box, terminal)
    pin_landings.append({"port": port, "pin_box_um": box, "pad_terminal_box_um": terminal})
assert len(pin_landings) == 9
j = {
    "passed": True,
    "native_overlap_count": 0,
    "signal_pin_landings": pin_landings,
    "audit_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    "signal_pads": 9,
    "power_ground_poc_pads": 28,
    "corner_cells": 4,
    "bond_windows": 37,
    "native_io_union_area_mm2": area,
    "native": native,
    "bonds": bonds,
    "side_intervals": sides,
    "scope": "LEF bounding-box packing, side abutment and METAL4 external signal pin landing only. Bond-window overlap is intentional; this does not establish GDS electrical LVS, ESD or EMIR.",
    "def_sha256": hashlib.sha256(a.design.read_bytes()).hexdigest(),
    "lef_sha256": {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in lefs},
}
a.out.write_text(json.dumps(j, indent=2) + "\n")
print(
    json.dumps(
        {
            key: j[key]
            for key in [
                "passed",
                "signal_pads",
                "power_ground_poc_pads",
                "bond_windows",
                "native_io_union_area_mm2",
            ]
        },
        indent=2,
    )
)
