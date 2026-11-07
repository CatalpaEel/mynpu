"""Minimum Manhattan pin-distance assignment over legal 100um IO slots."""

import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--points", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
points = {}
for row in a.points.read_text().splitlines():
    name, x, y = row.split()
    points.setdefault(name, []).append((float(x), float(y)))
slots = [
    (side, pos)
    for side in ["top", "bottom", "left", "right"]
    for pos in [160, 260, 360, 460, 1400, 1500, 1600, 1700]
]


# Use the core-facing PAD connection, not the external bond center.
def pinxy(side, pos):
    return {
        "top": (pos + 40, 1885),
        "bottom": (pos + 40, 115),
        "left": (115, pos + 40),
        "right": (1885, pos + 40),
    }[side]


names = sorted(points)
cost = [
    [
        sum(abs(x - pinxy(side, pos)[0]) + abs(y - pinxy(side, pos)[1]) for x, y in points[name])
        for side, pos in slots
    ]
    for name in names
]
# Rectangular Hungarian assignment; each signal gets a distinct legal slot.
n, m = len(names), len(slots)
u, v, matched, way = [0.0] * (n + 1), [0.0] * (m + 1), [0] * (m + 1), [0] * (m + 1)
for i in range(1, n + 1):
    matched[0], j0 = i, 0
    minimum, used = [float("inf")] * (m + 1), [False] * (m + 1)
    while True:
        used[j0], i0 = True, matched[j0]
        delta, j1 = float("inf"), 0
        for j in range(1, m + 1):
            if not used[j]:
                cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minimum[j]:
                    minimum[j], way[j] = cur, j0
                if minimum[j] < delta:
                    delta, j1 = minimum[j], j
        for j in range(m + 1):
            if used[j]:
                u[matched[j]] += delta
                v[j] -= delta
            else:
                minimum[j] -= delta
        j0 = j1
        if matched[j0] == 0:
            break
    while True:
        j1 = way[j0]
        matched[j0] = matched[j1]
        j0 = j1
        if j0 == 0:
            break
assignment = {names[matched[j] - 1]: slots[j - 1] for j in range(1, m + 1) if matched[j]}
old = {
    "clk_i": ("top", 300),
    "rst_ni": ("top", 1600),
    "tck_i": ("bottom", 250),
    "tms_i": ("bottom", 450),
    "td_i": ("bottom", 1450),
    "td_o": ("bottom", 1700),
    "boot_ready_i": ("left", 300),
    "npu_irq_o": ("right", 300),
    "cpu_debug_halted_o": ("right", 1600),
}
score = lambda mapping: sum(
    sum(
        abs(x - pinxy(*mapping[name])[0]) + abs(y - pinxy(*mapping[name])[1])
        for x, y in points[name]
    )
    for name in names
)
if score(assignment) >= score(old):
    assignment = old
result = {
    "objective": "Sum Manhattan distance from core-connected terminals to approximate core-facing pad pin over 32 fixed legal slots; optimal for this discrete cost only, not global routed optimum.",
    "before_cost_um": score(old),
    "after_cost_um": score(assignment),
    "assignment": assignment,
    "terminals_per_signal": {name: len(points[name]) for name in names},
}
a.out.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
a.out.write_text(
    "set optimized_signal_plan {"
    + " ".join(
        f"{name} {side} {pos} "
        + ("out" if name in ["td_o", "npu_irq_o", "cpu_debug_halted_o"] else "in")
        for name, (side, pos) in assignment.items()
    )
    + "}\n"
)
print(json.dumps(result))
