"""Audit exported file integrity and key interfaces; not foundry DRC/LVS."""
import gzip
import json
import re
from collections import Counter
from functools import lru_cache
from pathlib import Path
from gds_records import read_gds

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'mynpu/pnr/outputs/final'
top = 'mynpu_asic_top'
signals = {'clk_i','rst_ni','boot_ready_i','tck_i','tms_i','td_i','td_o','npu_irq_o','cpu_debug_halted_o'}
supplies = {'VDD','VSS','VDDPST','VSSPST'}
required = ['.def','.flat_lvs.v','.hier_postpnr.v','.sdc','.spef.gz','.sdf.gz','.lef','.gds.gz']
for suffix in required:
    assert (OUT/(top+suffix)).stat().st_size > 0, suffix
definition = (OUT/(top+'.def')).read_text()
units = int(re.search(r'UNITS DISTANCE MICRONS (\d+)', definition).group(1))
die_match = re.search(r'DIEAREA\s+\(\s*(\d+)\s+(\d+)\s*\)\s+\(\s*(\d+)\s+(\d+)\s*\)', definition)
die = [int(x)/units for x in die_match.groups()]
assert die == [0,0,2000,2000], die
pin_body = definition.split('\nPINS ',1)[1].split('END PINS',1)[0]
pins = set(re.findall(r'^-\s+(\S+)\s+\+', pin_body,re.M))
assert pins == signals | supplies, pins
cells, scale, missing = read_gds(OUT/(top+'.gds.gz'))
assert not missing, missing
assert abs(scale-0.0005) < 1e-12, scale
assert top in cells
labels = {entry.get('text') for entry in cells[top] if entry['kind']==12}
assert signals | supplies <= labels, (signals | supplies)-labels
@lru_cache(None)
def count_master(name, master):
    total = 0
    for entry in cells[name]:
        if 'ref' not in entry:
            continue
        factor = entry['array'][0]*entry['array'][1] if 'array' in entry else 1
        total += factor * (1 if entry['ref']==master else count_master(entry['ref'],master))
    return total
expected = {'RA1SHD_2048x32M8':2,'PDDW0204CDG':9,'PVDD1CDG':8,'PVSS1CDG':8,
            'PVDD2CDG':4,'PVSS2CDG':4,'PVDD2POC':4,'PCORNER':4,'PAD60LU_OBV':37}
gds_counts = {name:count_master(top,name) for name in expected}
assert gds_counts == expected, gds_counts
spef_nets = spef_ends = 0
spef_design = None
with gzip.open(str(OUT/(top+'.spef.gz')),'rt') as source:
    for line in source:
        if line.startswith('*DESIGN '): spef_design = line.split('"')[1]
        if line.startswith('*D_NET '): spef_nets += 1
        if line.strip()=='*END': spef_ends += 1
assert spef_design == top and spef_nets == spef_ends and spef_nets > 0
with gzip.open(str(OUT/(top+'.sdf.gz')),'rt') as source:
    sdf = source.read()
assert re.search(r'\(DESIGN\s+"'+top+r'"\)',sdf)
sdf_cells = len(re.findall(r'\(CELL\s',sdf))
assert sdf_cells > 1000
flat = (OUT/(top+'.flat_lvs.v')).read_text()
for line in re.findall(r'assign\s+([^;]+);',flat):
    assert not any(re.search(r'\b'+name+r'\b',line) for name in supplies), line
power_terms = []
for cell,name,body in re.findall(r'\b(PVDD2CDG|PVDD2POC|PVSS2CDG)\s+(\S+)\s*\((.*?)\);',flat,re.S):
    pin = 'VSSPST' if cell=='PVSS2CDG' else 'VDDPST'
    match = re.search(r'\.'+pin+r'\s*\(\s*([^\s)]+)\s*\)',body)
    assert match and match.group(1)==pin, (name,pin,body)
    power_terms.append(name+'/'+pin)
assert len(power_terms)==12, power_terms
result = {'export_integrity_passed':True,'scope':'File integrity, structure references and named interfaces; not DRC/LVS or SDF backannotation',
          'def_units_per_um':units,'die_um':die,'def_components':int(re.search(r'COMPONENTS (\d+)',definition).group(1)),
          'top_ports':sorted(pins),'gds_structure_count':len(cells),'gds_undefined_references':missing,
          'gds_dbu_um':scale,'gds_instance_counts':gds_counts,'spef_net_count':spef_nets,
          'spef_end_count':spef_ends,'sdf_cell_count':sdf_cells,'ordinary_io_supply_term_count':len(power_terms),
          'files':{(top+suffix):(OUT/(top+suffix)).stat().st_size for suffix in required}}
(ROOT/'mynpu/pnr/reports/export_audit.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
