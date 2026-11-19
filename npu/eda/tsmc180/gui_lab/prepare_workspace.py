#!/usr/bin/env python3.12
"""Create a separate backend worktree and prepare inputs; never run synthesis/PNR."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SERVER = REPO.parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, required=True, help='New worktree beside the project, not inside it')
p.add_argument('--branch', default=None)
p.add_argument('--reference-lab5', type=Path, default=SERVER/'eda-runs/20261118-main53655b5-lab5-r1')
p.add_argument('--reference-pnr', type=Path, default=SERVER/'eda-runs/20261118-main53655b5-fullchip-r1')
a = p.parse_args()
out = a.out.resolve()
if out.exists() or out.is_relative_to(REPO) or out.parent != SERVER:
    p.error('Choose a new sibling worktree beside this repository')
ref, pnr = a.reference_lab5.resolve(), a.reference_pnr.resolve()
for path in [ref/'rules/post.drc', ref/'workspace/mynpu_tech2000/tech.db', ref/'workspace/mynpu_ring2000', pnr/'scripts/synth_chip.tcl', SERVER/'eda-runs/20261109-lab5-all4/cdl/sram_ports.v', REPO/'npu/mnist/artifacts/model.json']:
    if not path.exists(): p.error('Missing local reference: '+str(path))
branch = a.branch or 'lab/backend-gui-'+datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
subprocess.run(['git', 'worktree', 'add', '-b', branch, str(out), 'HEAD'], cwd=REPO, check=True)
# Preserve the currently reviewed dirty RTL/doc changes without committing them.
changed = subprocess.check_output(['git','ls-files','--modified','--others','--exclude-standard','-z'],cwd=REPO).decode().split('\0')
for name in filter(None, changed):
    src = REPO/name
    if src.is_file():
        dst=out/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
shutil.copytree(REPO/'npu/mnist/artifacts',out/'npu/mnist/artifacts',dirs_exist_ok=True)
lab=out/'backend_lab'
shutil.copytree(HERE/'workspace_tools',lab)
# Rebase template paths when a different local reference is selected.
for template in (lab/'templates/signoff').iterdir():
    if template.is_file():
        template.write_text(template.read_text().replace(str(SERVER/'eda-runs/20261118-main53655b5-lab5-r1'),str(ref)))
(lab/'private').mkdir();(lab/'runs').mkdir();(lab/'screenshots').mkdir()
for folder in ['rules','reference']:
    shutil.copytree(ref/folder,lab/'private'/folder)
for folder in ['mynpu_tech2000','mynpu_ring2000']:
    shutil.copytree(ref/'workspace'/folder,lab/'private'/folder)
shutil.copy2(ref/'workspace/cds.lib',lab/'private/cds.lib')
(lab/'private/dummy').mkdir()
for src in (ref/'dummy').iterdir():
    if src.is_file():shutil.copy2(src,lab/'private/dummy'/src.name)
shutil.copy2(SERVER/'eda-runs/20261109-lab5-all4/cdl/sram_ports.v',lab/'private/sram_ports.v')
for src in (out/'npu/eda/tsmc180/fullchip').iterdir():
    if src.is_file() and src.suffix in {'.tcl','.py'}:shutil.copy2(src,lab/'templates/pnr'/src.name)
for name in ['cleanup_external_pad_routes.tcl','fix_current_bond_spacing.tcl','export_wb_final.tcl']:
    shutil.copy2(out/'npu/eda/tsmc180/verified_main53655b5_20261118'/name,lab/'templates/pnr'/name)
(lab/'templates/pnr/flow_paths.tcl').write_text(f'set pdk {{/home/almalinux/tsmc180}}\nset macro {{{SERVER}/soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8}}\n')
(lab/'templates/pnr/synth_chip.tcl').write_text((pnr/'scripts/synth_chip.tcl').read_text().replace(str(pnr),str(lab/'runs/chip')))
# Render tutorial paths for this generated instance.
text=(out/'npu/docs/backend-gui-lab.md').read_text().replace('/home/s2400012841/chip-fullstack-2026/mynpu-backend-gui-20261119',str(out))
(lab/'GUI-TUTORIAL.md').write_text(text)
(lab/'README.md.in').rename(lab/'README.md')
q=lab/'README.md';q.write_text(q.read_text().replace('/home/s2400012841/chip-fullstack-2026/mynpu-backend-gui-20261119',str(out)).replace('lab/backend-gui-20261119',branch))
(lab/'.gitignore').write_text('/private/\n/runs/\n/__pycache__/\n')
(lab/'screenshots/README.md').write_text('User screenshots go here. No new GUI screenshots have been generated.\n')
(lab/'config.json').write_text(json.dumps({'repo':str(out),'lab':str(lab),'server_root':str(SERVER),'reference_pnr':str(pnr),'reference_lab5':str(ref),'pdk':'/home/almalinux/tsmc180','macro':str(SERVER/'soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8'),'synth_period_ns':18,'report_period_ns':20,'die_um':1950,'signal_pads':9,'scope':'Prepared only; no synthesis/PNR/signoff performed'},indent=2)+'\n')
files=list((out/'npu/rtl').rglob('*.sv'))+[out/'external/lab3-ST/SoC_cv32e40p/soc/rtl/debug'/n for n in ['dm_top.sv','dm_sba.sv']]
(lab/'source_origin.json').write_text(json.dumps({'source_workspace':str(REPO),'git_base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),'copied_uncommitted_files':list(filter(None,changed)),'rtl_sha256':{str(x.relative_to(out)):hashlib.sha256(x.read_bytes()).hexdigest() for x in files}},indent=2)+'\n')
q=out/'npu/eda/tsmc180/prepare_run.py';q.write_text(q.read_text().replace('"planned_pnr_width_um": 2000','"planned_pnr_width_um": 1950').replace('"planned_pnr_height_um": 2000','"planned_pnr_height_um": 1950'))
for command in ['prepare-core','prepare-signoff','preflight']:
    subprocess.run([sys.executable,str(lab/'lab.py'),command],cwd=out,check=True)
print('Prepared without EDA computation:',out)
print('Tutorial:',lab/'GUI-TUTORIAL.md')
