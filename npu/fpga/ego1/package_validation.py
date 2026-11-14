"""Package a board kit only after a matching FPGA implementation has passed."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from jtag_validation import validate_assets

HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(build, assets, out):
    # Refuse to issue a usable-looking kit for an unbuilt/overfull FPGA design.
    needed = ('implementation_pass.txt', 'ego1_mynpu.bit', 'ego1_mynpu.mcs',
              'source_manifest.json', 'reports/timing_routed.rpt',
              'reports/utilization_routed.rpt', 'reports/drc.rpt')
    for name in needed:
        if not (build/name).is_file():
            raise ValueError(f'FPGA is not ready: missing {name}')
    manifest = validate_assets(assets)
    snapshot = json.loads((build/'source_manifest.json').read_text())
    if snapshot['part'] != manifest['part'] or snapshot['config'] != manifest['production_config']:
        raise ValueError('Build and firmware configuration differ')
    for name, expected in snapshot['sha256'].items():
        if digest(build/name) != expected:
            raise ValueError(f'Frozen build input changed: {name}')
    for name, expected in manifest['chip_sources_sha256'].items():
        if digest(build/'src'/name) != expected:
            raise ValueError(f'Build and validation chip RTL differ: {name}')
    out.mkdir(parents=True, exist_ok=False)
    shutil.copytree(assets, out/'assets')
    for name in ('ego1_mynpu.bit','ego1_mynpu.mcs','implementation_pass.txt'):
        shutil.copy2(build/name,out/name)
    scripts=out/'npu/fpga/ego1'
    scripts.mkdir(parents=True)
    for name in ('jtag_validation.py','start_openocd.sh','program_fpga.tcl','ft232h.cfg'):
        shutil.copy2(HERE/name,scripts/name)
    (out/'npu/debug').mkdir()
    shutil.copy2(HERE.parents[1]/'debug/target.cfg',out/'npu/debug/target.cfg')
    (out/'README.txt').write_text(
        f'EGo1 / xc7a35tcsg324-1 / {snapshot["clock_hz"]}Hz / ASIC architecture validation\n'
        f'FPGA CPU RF implementation: {snapshot.get("cpu_rf_implementation", "flipflop")}\n'
        '1. Program ego1_mynpu.bit via the board configuration USB (Vivado Hardware Manager).\n'
        '2. Connect the external FT232H J5 chain and attach it to WSL.\n'
        '3. In WSL, cd to this kit and run: bash npu/fpga/ego1/start_openocd.sh\n'
        '4. In another WSL terminal in this kit:\n'
        'python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode smoke --out results/smoke\n'
        'python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode reload --boots 20 --out results/reload\n'
        'python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode continuous --runs 1000 --boots 2 --out results/continuous\n'
        'All result directories must be new. Preserve failed logs. Do not use old architecture bitstreams.\n'
        'A kit is not proof of physical-board testing; inspect result.json after execution.\n')
    (out/'kit_manifest.json').write_text(json.dumps({
        'part':manifest['part'],'physical_board_tested':False,
        'cpu_rf_implementation':snapshot.get('cpu_rf_implementation','flipflop'),
        'sha256':{p.relative_to(out).as_posix():digest(p) for p in sorted(out.rglob('*')) if p.is_file()}
    },indent=2)+'\n')
    print(f'BOARD KIT PREPARED: {out}')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build',type=Path,required=True)
    p.add_argument('--assets',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    package(a.build.resolve(),a.assets.resolve(),a.out.resolve())
