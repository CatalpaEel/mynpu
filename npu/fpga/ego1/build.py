#!/usr/bin/env python3
"""Freeze a portable EGo1 build bundle, then optionally run Vivado locally."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
NPU = HERE.parents[1]
REPO = NPU.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, default=NPU / 'build/ego1')
parser.add_argument('--prepare-only', action='store_true')
parser.add_argument('--area', action='store_true', help='Try Vivado area strategies without changing RTL/configuration')
parser.add_argument('--area-medium', action='store_true', help='Use the less expensive medium area strategy')
parser.add_argument('--threads', type=int, choices=range(1, 9), default=4, help='Vivado thread ceiling, default 4')
parser.add_argument('--clock-mhz', type=int, choices=(10, 25, 50), default=25, help='Actual FPGA system clock, default 25 MHz')
parser.add_argument('--cpu-rf-lutram', action='store_true', help='FPGA-only CPU register-file mapping; ASIC sources unchanged')
parser.add_argument('--cnn-dsp', action='store_true', help='Use FPGA DSP mapping for CNN arithmetic')
parser.add_argument('--place-before-capacity-check', action='store_true', help='Defer estimated LUT capacity check until after placement; final default DRC is mandatory')
parser.add_argument('--vivado', default='vivado', help='Vivado executable, including .bat on Windows')
a = parser.parse_args()
if a.area and a.area_medium:
    parser.error('Choose --area or --area-medium, not both')
out = a.out.resolve()
if out.exists():
    parser.error('Choose a new --out directory to preserve previous evidence')
subprocess.run([sys.executable, str(NPU / 'scripts/gen_sources.py')], check=True)
files = [Path(s) for s in (NPU / 'build/sources.f').read_text().splitlines()]
files.append(HERE / 'ego1_soc_top.sv')
reference_files = list(files)
if a.cpu_rf_lutram:
    files = [p for p in files if p.name != 'cv32e40p_register_file_ff.sv']
    files.append(HERE / 'cv32e40p_register_file_lutram.sv')
out.mkdir(parents=True)
# Source snapshots keep all builds independent of later RTL edits and machine paths.
for src in dict.fromkeys(reference_files + files):
    dst = out / 'src' / src.relative_to(REPO)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
inc = REPO / 'external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include'
shutil.copytree(inc, out / 'include')
extras = (['cnn_dsp.xdc'] if a.cnn_dsp else [])
if a.place_before_capacity_check:
    extras += ['pre_place.tcl', 'post_place.tcl']
for name in ['ego1.xdc', 'build.tcl', *extras]:
    shutil.copy2(HERE / name, out / name)
config = json.loads((NPU / 'build_config.json').read_text())
keys = {'rf_bank_words': 'NPU_RF_BANK_WORDS',
        'matrix_queue_depth': 'NPU_MATRIX_QUEUE_DEPTH',
        'vector_queue_depth': 'NPU_VECTOR_QUEUE_DEPTH',
        'cnn_queue_depth': 'NPU_CNN_QUEUE_DEPTH',
        'stream_fifo_depth': 'NPU_STREAM_FIFO_DEPTH'}
tcl = 'set npu_defines {' + ' '.join(f'{v}={config[k]}' for k, v in keys.items()) + '}\n'
tcl += 'set npu_area_strategy ' + ('2' if a.area_medium else '1' if a.area else '0') + '\n'
tcl += 'set npu_threads ' + str(a.threads) + '\n'
tcl += 'set npu_system_mhz ' + str(a.clock_mhz) + '\n'
tcl += 'set npu_cnn_dsp ' + str(int(a.cnn_dsp)) + '\n'
tcl += 'set npu_place_before_capacity_check ' + str(int(a.place_before_capacity_check)) + '\n'
tcl += 'set npu_sources [list \\\n' + ''.join(
    '  [file join $run_dir {src/' + p.relative_to(REPO).as_posix() + '}] \\\n' for p in files) + ']\n'
(out / 'sources.tcl').write_text(tcl)
manifest = {p.relative_to(out).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(out.rglob('*')) if p.is_file()}
(out / 'source_manifest.json').write_text(json.dumps({
    'part': 'xc7a35tcsg324-1', 'board': 'EGo1 V2.2', 'clock_hz': a.clock_mhz * 1000000,
    'area_strategy': a.area,
    'medium_area_strategy': a.area_medium, 'threads': a.threads,
    'cpu_rf_implementation': 'lutram_lvt' if a.cpu_rf_lutram else 'flipflop',
    'cnn_dsp_requested': a.cnn_dsp,
    'estimated_lut_check_deferred_to_post_placement': a.place_before_capacity_check,
    'compiled_sources': [p.relative_to(REPO).as_posix() for p in files],
    'config': config, 'sha256': manifest}, indent=2) + '\n')
print(f'Prepared {out}', flush=True)
if a.prepare_only:
    print('Run inside this directory: vivado -mode batch -source build.tcl')
else:
    exe = shutil.which(a.vivado)
    if not exe:
        parser.error('Vivado not found; prepared bundle is available for another machine')
    with (out / 'launcher.log').open('w') as log:
        subprocess.run([exe, '-mode', 'batch', '-source', 'build.tcl'], cwd=out,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    if not (out / 'implementation_pass.txt').is_file():
        raise RuntimeError('Vivado exited without the implementation pass marker')
    print((out / 'implementation_pass.txt').read_text())
