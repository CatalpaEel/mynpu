"""Check fixed IO abutment against native M4 edge profiles, without claiming LVS."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEF = Path('/home/almalinux/tsmc180/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/tpd018nv_6lm.lef')
sizes = {}
for match in re.finditer(r'^MACRO\s+(\S+)(.*?)(?=^MACRO|\Z)', LEF.read_text(), re.M | re.S):
    size = re.search(r'\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)', match.group(2))
    if size:
        sizes[match.group(1)] = tuple(float(v) for v in size.groups())
text = (ROOT / 'mynpu/pnr/outputs/03_io_floorplan.def').read_text()
body = text.split('COMPONENTS ', 1)[1].split('END COMPONENTS', 1)[0]
sides = {name: [] for name in ('top', 'bottom', 'left', 'right')}
corners = []
for match in re.finditer(r'^-\s+(\S+)\s+(\S+)(.*?);', body, re.M | re.S):
    name, cell, details = match.groups()
    if cell not in sizes or not (name.startswith('i_pad_') or name.startswith('IOF_') or name.startswith('corner_')):
        continue
    pos = re.search(r'\+\s+(?:FIXED|PLACED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\S+)', details)
    if not pos:
        raise ValueError('IO not placed: ' + name)
    x, y = float(pos.group(1))/2000, float(pos.group(2))/2000
    orientation = pos.group(3)
    width, height = sizes[cell]
    if orientation in ('E', 'W', 'FE', 'FW'):
        width, height = height, width
    box = [x, y, x+width, y+height]
    if cell == 'PCORNER':
        corners.append({'name': name, 'box': box, 'orientation': orientation})
        continue
    if abs(y) < 0.0005:
        side, lo, hi = 'bottom', x, x+width
    elif abs(y+height-2000) < 0.0005:
        side, lo, hi = 'top', x, x+width
    elif abs(x) < 0.0005:
        side, lo, hi = 'left', y, y+height
    elif abs(x+width-2000) < 0.0005:
        side, lo, hi = 'right', y, y+height
    else:
        raise ValueError('IO does not touch die edge: ' + name)
    sides[side].append({'name': name, 'cell': cell, 'interval': [lo, hi], 'box': box, 'orientation': orientation})
geometry = json.loads((ROOT / 'setup/native_io_m4_geometry.json').read_text())
expected = [[6.2, 41.2], [42.215, 75.315], [76.315, 110.5]]
issues = []
def merged(intervals):
    result = []
    for lo, hi in sorted(intervals):
        if result and lo <= result[-1][1] + 0.0005:
            result[-1][1] = max(result[-1][1], hi)
        else:
            result.append([lo, hi])
    return result

corner_profile = geometry['profiles']['PCORNER']
if merged(corner_profile['right']) != expected or merged(corner_profile['top']) != expected:
    issues.append('Native corner rail-edge mismatch')
expected_corners = {
    'corner_bl': ([0, 0, 115, 115], 'N'),
    'corner_br': ([1885, 0, 2000, 115], 'FN'),
    'corner_tl': ([0, 1885, 115, 2000], 'FS'),
    'corner_tr': ([1885, 1885, 2000, 2000], 'S'),
}
for corner in corners:
    box, orientation = expected_corners[corner['name']]
    if corner['orientation'] != orientation or any(abs(a-b)>0.0005 for a,b in zip(corner['box'],box)):
        issues.append('Corner position/orientation ' + corner['name'])
for side, rows in sides.items():
    rows.sort(key=lambda row: row['interval'][0])
    cursor = 115.0
    for row in rows:
        if abs(row['interval'][0]-cursor) > 0.0005:
            issues.append('{} abutment at {}'.format(side, row['name']))
        cursor = row['interval'][1]
        profile = geometry['profiles'][row['cell']]
        if profile['left'] != expected or profile['right'] != expected:
            issues.append('Native M4 profile: ' + row['cell'])
    if abs(cursor-1885) > 0.0005:
        issues.append(side + ' incomplete')
assert len(corners) == 4
result = {'die_um': [2000, 2000], 'native_m4_common_edge_intervals_um': expected,
          'corner_native_edge_profiles_match': merged(corner_profile['right']) == expected and merged(corner_profile['top']) == expected,
          'sides': sides, 'corners': corners, 'issues': issues,
          'scope': 'IO side abutment and common native M4 rail-edge profiles; full merged-GDS LVS/ESD/EM not validated'}
(ROOT / 'mynpu/pnr/reports/io_native_geometry_audit.json').write_text(json.dumps(result, indent=2)+'\n')
print('Side instance counts:', {side: len(rows) for side, rows in sides.items()})
print('Issues:', issues)
if issues:
    raise SystemExit(1)
