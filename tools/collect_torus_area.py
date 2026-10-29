"""Collect completed mapped area/timing and actual placement capacity evidence."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(run):
    run = run.resolve()
    synth = run / 'mynpu/chip_synth'
    log = (synth / 'launcher.log').read_text(errors='replace')
    if 'Normal exit.' not in log or not any(marker in log.splitlines() for marker in
            ('GRID_FAST_AREA_PASS', 'GRID_FULL_SYNTHESIS_PASS')):
        raise ValueError('Synthesis has not completed: ' + str(run))
    manifest = json.loads((run / 'inputs/source_manifest.json').read_text())
    frozen_changed = [name for name, value in manifest['file_sha256'].items()
                      if digest(run / 'inputs/mynpu' / name) != value]
    if frozen_changed:
        raise ValueError('Frozen RTL was modified: ' + str(frozen_changed))
    library_changed = [name for name, value in manifest['library_sha256'].items()
                       if not Path(name).is_file() or digest(Path(name)) != value]
    if library_changed:
        raise ValueError('Library inputs changed since freezing: ' + str(library_changed))
    project = Path(manifest['source_project'])
    live_changed = [name for name, value in manifest['file_sha256'].items()
                    if not (project / name).is_file() or digest(project / name) != value]
    qor = (synth / 'qor.rpt').read_text()
    area = float(re.search(r'^Cell Area\s+([\d.]+)', qor, re.M)[1])
    slack = float(re.search(r'^sys_clk\s+(-?[\d.]+)\s+[\d.]+\s+\d+\s*$', qor, re.M)[1])
    gates = (synth / 'gates.rpt').read_text()
    macro = re.search(r'^RA1SHD_2048x32M8\s+(\d+)\s+([\d.]+)', gates, re.M)
    if not macro or int(macro[1]) != 2:
        raise ValueError('Expected exactly two SRAM macros')
    macro_area = float(macro[2])
    modules = {}
    for line in (synth / 'area.rpt').read_text().splitlines():
        fields = line.split()
        if fields and fields[0] in ('i_array', 'i_stream', 'i_cpu_core_i', 'i_memory'):
            modules[fields[0]] = float(fields[-3])
    physical = {}
    pnr = run / 'mynpu/pnr'
    for stage, name, marker in (
            ('01', 'floorplan_io', 'FLOW_STAGE_OK_CHIP_IO_FLOORPLAN'),
            ('02', 'powerplan', 'FLOW_STAGE_OK_CHIP_POWERPLAN'),
            ('03', 'placement', 'FLOW_STAGE_OK_CHIP_TIE_PRECTS_COMMANDS_COMPLETED')):
        path = pnr / (stage + '_launcher.log')
        if not path.exists():
            physical[name] = 'not_run'
            continue
        content = path.read_text(errors='replace')
        physical[name] = 'pass' if marker in content.splitlines() else 'incomplete_or_failed'
        match = re.search(r'Design has util ([\d.]+)% > 100%', content)
        if match:
            physical[name] = 'failed_capacity_IMPSP-190'
            physical['placement_utilization_percent'] = float(match[1])
        match = re.search(r'stdcell_area \d+ sites \(([\d.]+) um\^2\) / alloc_area \d+ sites \(([\d.]+) um\^2\)', content)
        if match:
            physical['placement_stdcell_area_um2'] = float(match[1])
            physical['placement_alloc_area_um2'] = float(match[2])
    physical['cts'] = 'not_collected' if (pnr / '04_launcher.log').exists() else 'not_run'
    physical['route'] = 'not_collected' if (pnr / '05_launcher.log').exists() else 'not_run'
    geometry = pnr / 'reports/floorplan_geometry.rpt'
    if geometry.exists():
        macros = []
        for line in geometry.read_text().splitlines():
            if line.startswith(('die ', 'core ')):
                box = list(map(float, re.findall(r'-?\d+(?:\.\d+)?', line)))
                physical[line.split()[0] + '_area_um2'] = (box[2]-box[0])*(box[3]-box[1])
            elif ' box=' in line:
                box = list(map(float, re.findall(r'-?\d+(?:\.\d+)?', line.split('box=')[1].split('}')[0])))
                macros.append((box[2]-box[0])*(box[3]-box[1]))
        if len(macros) == 2:
            macro_area = sum(macros)
    floorcheck = pnr / 'reports/floorplan_check.rpt'
    if floorcheck.exists():
        match = re.search(r'Core Utilization =\s*([\d.]+)', floorcheck.read_text())
        if match:
            physical['floorplan_core_utilization_percent'] = float(match[1])
    structural = (synth / 'check_design.rpt').read_text()
    for label in ('Unresolved References', 'Empty Modules', 'Undriven Leaf Pin(s)', 'Multidriven Leaf Pin(s)'):
        if not re.search(r'^'+re.escape(label)+r'\s+0\s*$', structural, re.M):
            raise ValueError('Structural check failed for '+label+': '+str(run))
    structural_report = 'unresolved.rpt' if (synth / 'unresolved.rpt').exists() else 'check_design.rpt'
    return dict(run=str(run), configuration=manifest['configuration'], cell_area_um2=area,
                macro_area_um2=macro_area, standard_cell_area_um2=area-macro_area,
                module_area_um2=modules, system_setup_slack_ps=slack,
                timing_scope='Mapped global-interconnect estimate; no routed timing conclusion',
                synthesis_mode='full' if 'GRID_FULL_SYNTHESIS_PASS' in log else 'fast_map',
                frozen_rtl_changed=frozen_changed, live_rtl_changed=live_changed,
                library_changed=library_changed,
                fits_2mm_die=False if physical.get('placement') == 'failed_capacity_IMPSP-190' else None,
                routed_50MHz_verified=False if physical['route'] == 'not_run' else None,
                physical=physical, report_sha256={name: digest(synth / name) for name in
                ('area.rpt', 'qor.rpt', 'timing.rpt', structural_report, 'launcher.log')})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--functional', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    current = collect(args.run)
    result = dict(current=current)
    if args.baseline:
        baseline = collect(args.baseline)
        result['baseline'] = baseline
        result['area_reduction_percent'] = 100*(1-current['cell_area_um2']/baseline['cell_area_um2'])
    if args.functional:
        functional = json.loads(args.functional.read_text())
        if not all(value['passed'] and value['independent_cycles_exact'] and
                   not value['changed_during_run'] for value in functional.values()):
            raise ValueError('Functional regression failed')
        result['functional'] = functional
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    print('Cell area %.6f mm2; sys_clk mapped setup slack %+.4f ns' %
          (current['cell_area_um2']/1e6, current['system_setup_slack_ps']/1000))
    if args.baseline:
        print('Area reduction %.2f%%' % result['area_reduction_percent'])
    print(args.out)


if __name__ == '__main__':
    main()
