#!/usr/bin/env python3.12
"""Prepare and drive an isolated TSMC180 exercise. Preparation never runs EDA."""
import argparse
import gzip
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent
REPO = LAB.parent
CFG = json.loads((LAB / 'config.json').read_text())
CORE, CHIP, SIGN = (LAB / 'runs' / n for n in ('core', 'chip', 'signoff'))
SHA = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
STAGES = {'01': 'pnr_01_floorplan_io', '02': 'pnr_02_powerplan',
          '03': 'pnr_03_place', '04': 'pnr_04_cts', '04b': 'pnr_04b_holdfix',
          '05': 'pnr_05_route', '06': 'pnr_06_finish', '07': 'pnr_07_export'}

def run(args, cwd=REPO, logfile=None):
    print('RUN:', ' '.join(map(str, args)), flush=True)
    if logfile:
        if logfile.exists():
            raise RuntimeError(f'Preserve existing log before retry: {logfile}')
        with logfile.open('w') as f:
            subprocess.run(list(map(str, args)), cwd=cwd, stdout=f, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(list(map(str, args)), cwd=cwd, check=True)

def no_exit(text):
    return re.sub(r'^exit(?:\s+\d+)?\s*$', '# GUI: keep the application open.', text, flags=re.M)

def emit_core_gui():
    text = (CORE / 'synth.tcl').read_text()
    cuts = [0, text.index('\nsyn_generic\n') + 1, text.index('\nsyn_map\n') + 1,
            text.index('\nsyn_opt\n') + 1, len(text)]
    names = ['01_setup', '02_generic', '03_map', '04_opt_export']
    for i, name in enumerate(names):
        body = no_exit(text[cuts[i]:cuts[i + 1]])
        if i == 3:
            body += '\nset f [open {' + str(CORE / 'gui_complete.txt') + '} w]\nputs $f {GUI synthesis commands completed; review reports separately.}\nclose $f\n'
        (CORE / ('gui_' + name + '.tcl')).write_text(body)

def prepare_core():
    if CORE.exists():
        raise RuntimeError('core already prepared; preserve it, use another workspace for a fresh run')
    run([sys.executable, REPO / 'npu/eda/tsmc180/prepare_run.py', '--out', CORE,
         '--pdk', CFG['pdk'], '--macro', CFG['macro'], '--effort', 'high',
         '--clock-gating', '--preserve-unit-boundaries', '--synth-period', '18', '--report-period', '20'])
    emit_core_gui()

def accept_synthesis(root, marker, outputs):
    missing = [str(root / x) for x in outputs if not (root / x).is_file() or not (root / x).stat().st_size]
    if missing:
        raise RuntimeError('Synthesis outputs missing: ' + ', '.join(missing))
    logs = [root / 'launcher.log', root / 'genus.log']
    source = next((p for p in logs if p.exists() and re.search(r'^' + marker + r'\s*$', p.read_text(errors='replace'), re.M)), None)
    if source is None:
        raise RuntimeError(f'No actual completion marker in {logs}; do not fabricate a pass log')
    if source.name != 'launcher.log':
        if (root / 'launcher.log').exists():
            raise RuntimeError('An incomplete launcher.log exists; archive it before accepting GUI log')
        shutil.copy2(source, root / 'launcher.log')
    (root / 'synthesis_acceptance.json').write_text(json.dumps({
        'log': str(source), 'log_sha256': SHA(source), 'marker': marker,
        'outputs_sha256': {x: SHA(root / x) for x in outputs},
        'scope': 'Synthesis command completion, not physical/timing/signoff acceptance'}, indent=2) + '\n')

def accept_core():
    accept_synthesis(CORE, 'DUAL_BANK_ASIC_SYNTH_PASS', ['optimized.v', 'optimized.sdc', 'reports/area.rpt', 'reports/timing.rpt'])

def emit_chip_gui(root):
    for key, name in STAGES.items():
        p = root / 'scripts' / (name + '.tcl')
        (root / 'scripts' / ('gui_' + name + '.tcl')).write_text('source [file join [file dirname [info script]] gui_env.tcl]\n' + no_exit(p.read_text()) + '\nfit\n')
    p = root / 'scripts/synth_chip.tcl'
    (root / 'scripts/gui_synth_chip.tcl').write_text(no_exit(p.read_text()))
    # Explicit optional ECOs: user must inspect their own violations first.
    for name in ['cleanup_external_pad_routes', 'fix_current_bond_spacing', 'export_wb_final']:
        p = root / 'scripts' / (name + '.tcl')
        (root / 'scripts' / ('gui_' + name + '.tcl')).write_text('source [file join [file dirname [info script]] gui_env.tcl]\n' + no_exit(p.read_text()) + '\nfit\n')
    (root / 'scripts/gui_restore.tcl').write_text('''# Load a saved checkpoint, without running the modifying stage again.
set lab_chip_root [file normalize [file join [file dirname [info script]] ..]]
proc lab_restore {checkpoint} {
    global lab_chip_root
    set p [file join $lab_chip_root mynpu pnr checkpoints $checkpoint.enc.dat]
    if {![file exists $p]} {error "Checkpoint not yet generated: $p"}
    restoreDesign $p mynpu_asic_top
    fit
}
proc lab_snap {name} {
    global lab_chip_root
    if {![regexp {^[A-Za-z0-9_-]+$} $name]} {error "Use a simple screenshot name"}
    set path [file normalize [file join $lab_chip_root .. .. screenshots $name.png]]
    if {[file exists $path]} {error "Screenshot exists; choose a new name: $path"}
    file mkdir [file dirname $path]
    update idletasks
    gui_dump_picture $path -format PNG -width 1400 -height 1100
    puts "SCREENSHOT_SAVED $path"
}
puts {Use: lab_restore 10_post_cts (or 03_io_floorplan / 06_powerplan / 08_post_tie / 11_pre_route / 12_routed / 13_finished)}
''')

def prepare_chip():
    accept_core()
    run([sys.executable, REPO / 'npu/eda/tsmc180/prepare_chip.py', '--core', CORE, '--out', CHIP])
    for p in (LAB / 'templates/pnr').iterdir():
        if p.is_file():
            shutil.copy2(p, CHIP / 'scripts' / p.name)
    emit_chip_gui(CHIP)
    m = json.loads((CHIP / 'manifest.json').read_text())
    m['exercise'] = {'config': str(LAB / 'config.json'), 'script_templates': str(LAB / 'templates/pnr'), 'no_pnr_executed_at_preparation': True}
    m['frozen_script_sha256'] = {p.name: SHA(p) for p in (CHIP / 'scripts').iterdir() if p.is_file()}
    (CHIP / 'manifest.json').write_text(json.dumps(m, indent=2) + '\n')

def prepare_signoff():
    if SIGN.exists():
        raise RuntimeError('signoff already prepared; preserve prior evidence before creating a new revision')
    # This builds empty libraries and rule copies only; no result/netlist is copied.
    for folder in ['scripts', 'workspace', 'inputs', 'outputs', 'logs', 'cdl', 'drc_pre', 'drc_post', 'lvs', 'lvs_strict', 'antenna', 'wb', 'dummy']:
        (SIGN / folder).mkdir(parents=True)
    old = Path(CFG['reference_lab5'])
    for folder in ['rules', 'reference']:
        shutil.copytree(LAB / 'private' / folder, SIGN / folder)
    for folder in ['mynpu_tech2000', 'mynpu_ring2000']:
        shutil.copytree(LAB / 'private' / folder, SIGN / 'workspace' / folder)
    shutil.copy2(LAB / 'private/cds.lib', SIGN / 'workspace/cds.lib')
    for p in (LAB / 'private/dummy').iterdir():
        if p.is_file(): shutil.copy2(p, SIGN / 'dummy' / p.name)
    for p in (LAB / 'templates/signoff').iterdir():
        shutil.copy2(p, SIGN / 'scripts' / p.name)
    for folder in ['rules', 'dummy', 'scripts']:
        for p in (SIGN / folder).iterdir():
            if not p.is_file(): continue
            try: text = p.read_text()
            except UnicodeError: continue
            text = text.replace(str(old), str(SIGN))
            if p.name == 'run_signoff.py':
                text = re.sub(r"R=Path\(__file__\).*?;W=R/'workspace'", f"R=Path(__file__).resolve().parents[1];ROOT=Path({CFG['server_root']!r});PNR=Path({str(CHIP)!r});W=R/'workspace'", text, count=1)
                text = text.replace("ROOT/'eda-runs/20261109-lab5-all4/cdl/sram_ports.v'", f"Path({str(LAB / 'private/sram_ports.v')!r})")
            if p.name == 'collect_results.py':
                text = text.replace('ROOT=R.parent.parent', f"ROOT=Path({CFG['server_root']!r})")
                text = text.replace("ROOT/'mynpu-softpe/npu/eda/tsmc180/collect_lab5.py'", f"Path({str(REPO / 'npu/eda/tsmc180/collect_lab5.py')!r})")
                text = re.sub(r"out=ROOT/'mynpu-softpe/npu/reports/[^']+'", "out=R/'outputs/lab5_exercise_validation.json'", text)
            p.write_text(text)
    p = SIGN / 'workspace/cds.lib'
    p.write_text(p.read_text().replace(str(old), str(SIGN)))
    (SIGN / 'PREPARED_NOT_RUN.txt').write_text('Private technology/ring references and rule templates only. No design GDS, netlist, DRC or LVS result has been copied.\n')

def ready_signoff():
    out = CHIP / 'mynpu/pnr'
    if 'No DRC violations were found' not in (out / 'reports/13_final_drc.rpt').read_text():
        raise RuntimeError('Native DRC must be reviewed and cleared before final signoff')
    if 'Found no problems or warnings.' not in (out / 'reports/13_final_pg.rpt').read_text():
        raise RuntimeError('Core PG connectivity needs review')
    if 'No Violations Found' not in (out / 'reports/13_final_antenna.rpt').read_text():
        raise RuntimeError('Native antenna violations remain')
    for folder in ['final_setup', 'final_hold']:
        reports = list((out / 'reports' / folder).glob('*summary.gz'))
        if not reports: raise RuntimeError('Missing final timing: ' + folder)
        for p in reports:
            text = gzip.open(p, 'rt').read()
            for key in ['WNS (ns)', 'TNS (ns)', 'Violating Paths']:
                match = re.search(r'\|\s*' + re.escape(key) + r':\|\s*(-?\d+(?:\.\d+)?)', text)
                if not match or float(match[1]) < 0 or (key != 'WNS (ns)' and float(match[1]) != 0):
                    raise RuntimeError('Final timing check failed: ' + str(p))
    run([sys.executable, REPO / 'npu/eda/tsmc180/audit_chip_io.py', '--def', out / 'outputs/final/mynpu_asic_top.def', '--out', CHIP / 'io_audit.json', '--die-size', '1950'])
    run([sys.executable, REPO / 'npu/eda/tsmc180/audit_chip_exports.py', '--run', CHIP])
    paths = [out / 'outputs/final' / n for n in ['mynpu_asic_top.gds.gz', 'mynpu_asic_top.flat_lvs.v', 'mynpu_asic_top.def']]
    (CHIP / 'signoff_input_ready.json').write_text(json.dumps({'input_sha256': {str(p): SHA(p) for p in paths}, 'scope': 'Native DRC/timing and export checks; not Calibre acceptance'}, indent=2) + '\n')

def preflight():
    print('Workspace:', REPO)
    print('Configuration:', json.dumps(json.loads((REPO / 'npu/build_config.json').read_text())))
    for tool in ['genus', 'innovus', 'virtuoso', 'strmin', 'strmout', 'calibre', 'vcs']:
        path = shutil.which(tool)
        if not path: raise RuntimeError('Tool not in PATH: ' + tool)
        print(tool, path)
    for path in [CFG['pdk'], CFG['macro']]:
        if not Path(path).is_dir(): raise RuntimeError('Missing library: ' + path)
    origin = json.loads((LAB / 'source_origin.json').read_text())
    for name, h in origin['rtl_sha256'].items():
        if SHA(REPO / name) != h: raise RuntimeError('Exercise RTL drift: ' + name)
    for name, h in json.loads((CORE / 'library_manifest.json').read_text()).items():
        if SHA(name) != h: raise RuntimeError('Library drift: ' + name)
    print('Preflight passed; no EDA jobs launched.')

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('command', choices=['preflight', 'prepare-core', 'accept-core', 'prepare-chip', 'accept-chip', 'batch-core', 'batch-chip', 'batch-stage', 'prepare-signoff', 'ready-signoff', 'signoff', 'status'])
p.add_argument('--stage', choices=STAGES)
p.add_argument('--tag', default='exercise')
p.add_argument('--signoff-name', default='signoff', help='Independent signoff directory, e.g. signoff-r1 after an ECO')
a = p.parse_args()
if not re.fullmatch(r'signoff(?:-[a-zA-Z0-9_-]+)?', a.signoff_name):
    p.error('Use signoff or signoff-NAME without path separators')
SIGN = LAB / 'runs' / a.signoff_name
try:
    if a.command == 'preflight': preflight()
    elif a.command == 'prepare-core': prepare_core()
    elif a.command == 'accept-core': accept_core()
    elif a.command == 'prepare-chip': prepare_chip()
    elif a.command == 'accept-chip': accept_synthesis(CHIP / 'mynpu/chip_synth', 'FLOW_STAGE_OK_CHIP_SYNTHESIS', ['mynpu_asic_top.postsyn.v', 'area.rpt', 'timing.rpt'])
    elif a.command == 'batch-core': run(['genus', '-no_gui', '-batch', '-files', 'synth.tcl'], CORE, CORE / 'launcher.log')
    elif a.command == 'batch-chip': run(['genus', '-no_gui', '-batch', '-files', 'scripts/synth_chip.tcl'], CHIP, CHIP / 'mynpu/chip_synth/launcher.log')
    elif a.command == 'batch-stage':
        if not a.stage: p.error('--stage required')
        run([sys.executable, REPO / 'npu/eda/tsmc180/run_fullchip.py', '--run', CHIP, '--stages', a.stage, '--tag', a.tag])
    elif a.command == 'prepare-signoff': prepare_signoff()
    elif a.command == 'ready-signoff': ready_signoff()
    elif a.command == 'signoff':
        ready_signoff()
        run([sys.executable, SIGN / 'scripts/run_signoff.py'], SIGN)
        run([sys.executable, SIGN / 'scripts/collect_results.py'], SIGN)
    else:
        print(json.dumps({'core_prepared': CORE.exists(), 'core_netlist_present': (CORE / 'optimized.v').exists(), 'chip_prepared': CHIP.exists(), 'routed_checkpoint_present': (CHIP / 'mynpu/pnr/checkpoints/12_routed.enc.dat').exists(), 'signoff_prepared': SIGN.exists(), 'signoff_result_present': (SIGN / 'outputs/signoff_validation.json').exists()}, indent=2))
except (RuntimeError, FileNotFoundError, subprocess.CalledProcessError) as e:
    raise SystemExit(str(e))
