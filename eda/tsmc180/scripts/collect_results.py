#!/usr/bin/python3
"""Collect actual tool reports; completion markers alone are not signoff."""
import gzip
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PNR = ROOT / 'mynpu/pnr'

def read(path):
    path = ROOT / path
    return path.read_text(errors='replace') if path.is_file() else ''

def marker(path, value):
    return value in read(path).splitlines()

def area(path, module):
    match = re.search(r'^' + re.escape(module) + r'\s+(\d+)\s+([\d.]+)\s+([\d.]+)', read(path), re.M)
    if not match:
        return None
    cells, footprint, nets = match.groups()
    sram = 2 * 554.595 * 723.85 / 1e6
    return {'cell_count': int(cells), 'cell_area_mm2': float(footprint)/1e6,
            'sram_area_mm2': sram, 'standard_cell_area_mm2': float(footprint)/1e6-sram,
            'estimated_net_area_mm2': float(nets)/1e6}

def timing(directory):
    matches = sorted((PNR / 'reports' / directory).glob('*.summary.gz'))
    if not matches:
        return None
    with gzip.open(str(matches[-1]), 'rt') as source:
        text = source.read()
    matches[-1].with_suffix('').write_text(text)
    result = {}
    for label, key, converter in [('WNS (ns)', 'wns_ns', float), ('TNS (ns)', 'tns_ns', float),
                                  ('Violating Paths', 'violating_paths', int), ('All Paths', 'analyzed_paths', int)]:
        match = re.search(r'\|\s*'+re.escape(label)+r'\s*:\|\s*([-+\d.]+)', text)
        result[key] = converter(match.group(1)) if match else None
    return result

audit_path = PNR / 'reports/io_native_geometry_audit.json'
audit = json.loads(audit_path.read_text()) if audit_path.exists() else None
expected_pads = {row['name'] for rows in audit['sides'].values() for row in rows if row['name'].startswith('i_pad_')} if audit else set()

def placement(relative):
    text = read('mynpu/pnr/reports/' + relative)
    if not text:
        return None
    result = {}
    for label, key in [('Placed', 'placed'), ('Unplaced', 'unplaced')]:
        match = re.search(r'Number of '+label+r' Instances\s*=\s*(\d+)', text)
        result[key] = int(match.group(1)) if match else None
    categories = {}
    for kind, body in re.findall(r'set pchk(\w+)List\s+\[list(.*?)\]', text, re.S):
        categories[kind] = re.findall(r'\{([^}]+)\}', body)
    overlaps = categories.get('IoOverlap', [])
    result['io_overlap_count'] = len(overlaps)
    result['io_overlaps_match_bond_pad_plan'] = set(overlaps) == expected_pads
    result['other_violation_lists'] = {key: val for key, val in categories.items() if key != 'IoOverlap' and val}
    return result

def connectivity(relative):
    text = read('mynpu/pnr/reports/' + relative)
    if not text:
        return None
    codes = {code: int(count) for count, code in re.findall(r'(\d+) Problem\(s\) \((IMPVFC-\d+)\)', text)}
    return {'diagnostic_counts': codes,
            'dangling_endpoints': codes.get('IMPVFC-94', 0),
            'no_routing_nets': re.findall(r'Net ([^:\n]+): no routing', text),
            'other_diagnostic_codes': {key: val for key, val in codes.items() if key not in ('IMPVFC-94', 'IMPVFC-98')},
            'raw_report': str(PNR / 'reports' / relative)}

def drc(relative):
    text = read('mynpu/pnr/reports/' + relative)
    return None if not text else 'No DRC violations were found' in text

stages = {
    'core_synthesis': marker('mynpu/synth/launcher.log', 'FLOW_STAGE_OK_MYNPU_TSMC180_SYNTHESIS'),
    'chip_synthesis': marker('mynpu/chip_synth/launcher.log', 'FLOW_STAGE_OK_CHIP_SYNTHESIS') or marker('mynpu/chip_synth/launcher.log', 'GRID_FULL_SYNTHESIS_PASS'),
    'io_floorplan': marker('mynpu/pnr/01_launcher.log', 'FLOW_STAGE_OK_CHIP_IO_FLOORPLAN'),
    'powerplan': marker('mynpu/pnr/02_launcher.log', 'FLOW_STAGE_OK_CHIP_POWERPLAN'),
    'placement': marker('mynpu/pnr/03_launcher.log', 'FLOW_STAGE_OK_CHIP_TIE_PRECTS_COMMANDS_COMPLETED'),
    'cts': marker('mynpu/pnr/04_launcher.log', 'FLOW_STAGE_OK_CHIP_CTS_COMMANDS_COMPLETED'),
    'cts_hold_repair': marker('mynpu/pnr/04b_launcher.log', 'FLOW_STAGE_OK_CHIP_CTS_HOLDFIX_COMMANDS_COMPLETED'),
    'routing': marker('mynpu/pnr/05_launcher.log', 'FLOW_STAGE_OK_CHIP_ROUTE_COMMANDS_COMPLETED'),
    'final_checks_and_filler': marker('mynpu/pnr/06_launcher.log', 'FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED'),
    'final_export': marker('mynpu/pnr/07_launcher.log', 'FLOW_STAGE_OK_CHIP_FINAL_EXPORT'),
}
core_geometry = re.search(r'^core\s+\{([^}]+)\}', read('mynpu/pnr/reports/floorplan_geometry.rpt'), re.M)
report = {
    'configuration': {'rtl': 'current workspace snapshot; see inputs/source_manifest.json', 'NPU_LANES': 4,
                      'CPU_SRAM_BYTES': 8192, 'NPU_SRAM_BYTES': 8192, 'USE_ASIC_SRAM': 1,
                      'signal_pads': 9, 'power_pads': 28, 'bond_pads': 37, 'corners': 4,
                      'firmware_observation_outputs': 'not bonded; use existing JTAG/DMI/SBA mailbox'},
    'die_um': [2000, 2000], 'core_box_um': [float(v)for v in core_geometry[1].split()]if core_geometry else None,
    'completed_tool_stages': stages,
    'core_synthesis_area': area('mynpu/synth/area.rpt', 'mynpu_soc_top'),
    'chip_synthesis_area': area('mynpu/chip_synth/area.rpt', 'mynpu_asic_top'),
    'timing': {key: timing(key) for key in ('preCTS', 'postCTS', 'postCTS_hold', 'postCTS_holdFix_setup_check',
               'postCTS_holdFix_hold_check', 'postRoute', 'postRoute_hold', 'final_setup', 'final_hold')},
    'placement': {key: placement(value) for key, value in [('preCTS', '08_post_tie_place.rpt'), ('postCTS', '10_cts_place.rpt'), ('final', '13_final_place.rpt')]},
    'powerplan_drc_clean': drc('06_powerplan_drc.rpt'),
    'routing_drc_clean': drc('12_route_drc.rpt'), 'final_drc_clean': drc('13_final_drc.rpt'),
    'routing_antenna_clean': 'No Violations Found' in read('mynpu/pnr/reports/12_route_antenna.rpt') if read('mynpu/pnr/reports/12_route_antenna.rpt') else None,
    'final_antenna_clean': 'No Violations Found' in read('mynpu/pnr/reports/13_final_antenna.rpt') if read('mynpu/pnr/reports/13_final_antenna.rpt') else None,
    'connectivity': {key: connectivity(value) for key, value in [('powerplan_core', '06_core_pg.rpt'), ('powerplan_io', '06_io_pg.rpt'), ('route_signal', '12_route_signal.rpt'), ('route_pg', '12_route_pg.rpt'), ('final_signal', '13_final_signal.rpt'), ('final_pg', '13_final_pg.rpt')]},
    'io_geometry_audit_issues': audit['issues'] if audit else None,
    'calibre': {
        'simple_drc_license_probe_succeeded': 'TOTAL RULECHECKS EXECUTED = 1' in read('probe/calibre/launcher.log'),
        'hier_lvs_license_acquired': 'mgc_s license acquired (calibrehlvs requested)' in read('probe/calibre_lvs/launcher.log'),
        'lvs_license_acquired': 'mgc_s license acquired (calibrelvs requested)' in read('probe/calibre_lvs/launcher.log'),
        'probe_is_foundry_signoff': False,
    },
    'scope': ['Single TT view; native low-effort post-route extraction with supplied captable',
              'Retain actual PG dangling-end and IO abstract no-routing diagnostics; see raw reports',
              'No foundry DRC/LVS, multi-corner STA, IR/EM/ESD or tapeout signoff is claimed',
              'RTL provenance and configuration are recorded in inputs/source_manifest.json; scripts are frozen in scripts/'],
    'tapeout_signoff_complete': False,
}
export_audit = PNR / 'reports/export_audit.json'
report['export_audit'] = json.loads(export_audit.read_text()) if export_audit.exists() else None
# Post-CTS repair is conditional; its absence alone does not mean routing failed.
report['optional_stages'] = ['cts_hold_repair']
report['innovus_run_and_export_completed'] = all(value for key, value in stages.items() if key not in ('cts_hold_repair', 'core_synthesis')) and bool(report['export_audit'] and report['export_audit']['export_integrity_passed'])
if not (ROOT / 'probe/calibre/launcher.log').is_file():
    report['calibre']['simple_drc_license_probe_succeeded'] = None
if not (ROOT / 'probe/calibre_lvs/launcher.log').is_file():
    report['calibre']['hier_lvs_license_acquired'] = None
    report['calibre']['lvs_license_acquired'] = None
manifest = ROOT / 'inputs/source_manifest.json'
if manifest.is_file():
    report['source_manifest'] = 'inputs/source_manifest.json'
    report['configuration'].update(json.loads(manifest.read_text())['configuration'])
checks = {'assets': ('assets.log', 'Asset checks PASS'),
          'asic_soc': ('asic_soc.log', '[SOC-ASIC-STRESS] PASS'),
          'asic_random': ('asic_random.log', '[CNN-VECTOR-STRESS] PASS'),
          'fpga_edges': ('fpga_edges.log', '[CNN-EDGES] PASS')}
report['functional_validation'] = {}
for name, (filename, success) in checks.items():
    path = ROOT / 'validation' / filename
    data = path.read_text(errors='replace') if path.is_file() else None
    report['functional_validation'][name] = None if data is None else success in data and 'Fatal:' not in data
logs = [ROOT / 'mynpu/synth/launcher.log', ROOT / 'mynpu/chip_synth/launcher.log']
logs.extend(PNR.glob('*_launcher.log'))
report['tool_error_lines'] = {
    str(path.relative_to(ROOT)): len(re.findall(r'^(?:Error\s*:|Fatal\s*:|\*\*ERROR|\*\*FATAL)', path.read_text(errors='replace'), re.M))
    for path in logs if path.is_file()
}
report['innovus_run_and_export_completed'] &= not any(report['tool_error_lines'].values())
setup = report['timing']['final_setup']
hold = report['timing']['final_hold']
report['final_single_tt_setup_hold_met'] = bool(setup and hold and setup['violating_paths']==0 and hold['violating_paths']==0 and setup['wns_ns']>=0 and hold['wns_ns']>=0)
(ROOT / 'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'completed_tool_stages': stages, 'chip_synthesis_area': report['chip_synthesis_area'],
                  'postRoute': report['timing']['postRoute'], 'final_setup': report['timing']['final_setup'],
                  'final_hold': report['timing']['final_hold'], 'final_drc_clean': report['final_drc_clean']}, indent=2))
