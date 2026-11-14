"""Emit the constrained PAD plan and truthful geometric-distance metadata."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--points', type=Path, required=True)
p.add_argument('--manifest', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
m = json.loads(a.manifest.read_text())
plan = m['pad_experiment']['signal_plan'].split()
assert len(plan) == 36
assignment = {plan[i]: (plan[i + 1], float(plan[i + 2])) for i in range(0, len(plan), 4)}
points = {}
for line in a.points.read_text().splitlines():
    name, x, y = line.split()
    points.setdefault(name, []).append((float(x), float(y)))
assert set(points) == set(assignment)
width, height = m['die_um']
def pin(side, pos):
    return {'left': (115, pos + 30), 'right': (width - 115, pos + 30),
            'top': (pos + 30, height - 115), 'bottom': (pos + 30, 115)}[side]
score = sum(abs(x - pin(*assignment[n])[0]) + abs(y - pin(*assignment[n])[1])
            for n, pts in points.items() for x, y in pts)
a.out.write_text('set optimized_signal_plan {' + ' '.join(plan) + '}\n')
a.out.with_suffix('.json').write_text(json.dumps({
    'objective': 'Fixed left-JTAG and paired-supply plan; no global optimality claim. Geometric estimate, not routed wirelength.',
    'assignment': assignment, 'after_cost_um': score,
    'terminals_per_signal': {n: len(v) for n, v in points.items()}}, indent=2) + '\n')
