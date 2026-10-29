"""Run frozen stages with tool-error and setup/hold checks between stages."""
import argparse
import gzip
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path)
    p.add_argument('--wait-synthesis',action='store_true')
    p.add_argument('--route-repair-rounds',type=int,default=4,
                   help='Maximum incremental route repair rounds; each preserves the prior database and reports (0..6)')
    p.add_argument('--start-stage',choices=('01','02','03','04','05','06','07'),default='01',
                   help='Resume after inspecting/preserving earlier stages; existing stage logs are never overwritten')
    a=p.parse_args();run=a.run.resolve()
    if not 0<=a.route_repair_rounds<=6:p.error('--route-repair-rounds must be in 0..6')
    frozen=run/'scripts/frozen_run_flow.py'
    if frozen.is_file()and Path(__file__).resolve()!=frozen:
        os.execv(sys.executable,[sys.executable,str(frozen),*sys.argv[1:]])
    log=run/'mynpu/chip_synth/launcher.log'
    while True:
        data=log.read_text(errors='replace')if log.is_file()else''
        if 'GRID_FULL_SYNTHESIS_PASS'in data.splitlines():break
        if not a.wait_synthesis or re.search(r'^(?:Error\s*:|Fatal\s*:|\*\*ERROR)',data,re.M):raise SystemExit('Synthesis incomplete/failed')
        time.sleep(15)
    audit_log=run/'mynpu/chip_synth/constraint_audit_launcher.log'
    if not audit_log.exists():
        with audit_log.open('x')as stream:
            result=subprocess.run(['bash','-c','source /etc/profile.d/eda.sh\nexec genus -no_gui -batch -abort_on_error -disable_user_startup -files "$1"',
                'genus-constraint-audit',str(run/'scripts/check_chip_constraints.tcl')],cwd=run/'mynpu/chip_synth',stdout=stream,stderr=subprocess.STDOUT)
        if result.returncode:raise RuntimeError('Synthesis constraint audit failed')
    audit=audit_log.read_text(errors='replace')
    if 'FLOW_STAGE_OK_CHIP_CONSTRAINT_AUDIT'not in audit.splitlines()or re.search(r'^(?:Error\s*:|Fatal\s*:|\*\*ERROR)',audit,re.M):
        raise RuntimeError('Missing/failed synthesis constraint audit')
    def timing(stage):
        paths=sorted((run/'mynpu/pnr/reports'/stage).glob('*.summary.gz'))
        if not paths:raise RuntimeError('Missing timing summary: '+stage)
        with gzip.open(paths[-1],'rt')as f:data=f.read()
        match=re.search(r'\|\s*WNS \(ns\)\s*:\|\s*([-+\d.]+)',data)
        if not match:raise RuntimeError('Missing WNS: '+stage)
        paths_match=re.search(r'\|\s*Violating Paths\s*:\|\s*(\d+)',data)
        if not paths_match:raise RuntimeError('Missing violating-path count: '+stage)
        return float(match[1]),int(paths_match[1])
    def timing_met(result):
        # Rounded -0.000ns must not hide a real violating path.
        return result[0]>=0 and result[1]==0
    def antenna_met(stage):
        path=run/'mynpu/pnr/reports'/(stage+'_antenna.rpt')
        return path.is_file()and'No Violations Found'in path.read_text()
    def stage(n,marker,extra=None):
        if int(n.rstrip('b'))<int(a.start_stage):return
        print('Starting',n,flush=True);env=dict(os.environ);env.update(extra or{})
        runner=run/'scripts/frozen_run_stage.sh'
        if not runner.is_file():runner=ROOT/'eda/tsmc180/run_stage.sh'
        result=subprocess.run(['bash',str(runner),str(run),n],cwd=ROOT,env=env)
        path=run/'mynpu/pnr'/(n+'_launcher.log');data=path.read_text(errors='replace')
        errors=re.findall(r'^(?:Error\s*:|Fatal\s*:|\*\*ERROR|\*\*FATAL).*',data,re.M)
        if result.returncode or errors or('FLOW_STAGE_OK_'+marker)not in data.splitlines():raise RuntimeError('Stage '+n+' failed: '+str(errors))
        print('Completed',n,flush=True)
    for n,marker in [('01','CHIP_IO_FLOORPLAN'),('02','CHIP_POWERPLAN'),('03','CHIP_TIE_PRECTS_COMMANDS_COMPLETED'),('04','CHIP_CTS_COMMANDS_COMPLETED')]:stage(n,marker)
    setup,hold=timing('postCTS'),timing('postCTS_hold')
    print('postCTS setup/hold (WNS ns, violating paths):',setup,hold,flush=True)
    if not timing_met(hold) and timing_met(setup):stage('04b','CHIP_CTS_HOLDFIX_COMMANDS_COMPLETED')
    stage('05','CHIP_ROUTE_COMMANDS_COMPLETED')
    def route_clean():
        drc=run/'mynpu/pnr/reports/12_route_drc.rpt'
        return drc.is_file()and'No DRC violations were found'in drc.read_text()and antenna_met('12_route')
    if int(a.start_stage)<=5:
        for repair_round in range(a.route_repair_rounds):
            if route_clean():break
            out=run/'mynpu/pnr'
            archive=out/'attempts'/('auto-route-repair-%02d-%d'%(repair_round+1,time.time_ns()))
            archive.mkdir(parents=True)
            for name in ('12_routed.enc','12_routed.enc.dat'):
                source=out/'checkpoints'/name
                if source.is_dir():shutil.copytree(source,archive/name)
                else:shutil.copy2(source,archive/name)
            for source in (out/'reports').glob('12*'):
                if source.is_file():shutil.copy2(source,archive/source.name)
            for name in ('postRoute','postRoute_hold'):
                if(out/'reports'/name).is_dir():shutil.copytree(out/'reports'/name,archive/name)
            for name in ('pnr_05b_routefix.tcl','repair_antenna_diodes.tcl','repair_pg_pin_access.tcl'):
                shutil.copy2(run/'scripts'/name,archive/name)
            for name in ('05_launcher.log','05b_launcher.log'):
                source=out/name
                if source.is_file():
                    with source.open('rb')as inp,gzip.open(archive/(name+'.gz'),'wb')as dest:shutil.copyfileobj(inp,dest)
                    if name=='05b_launcher.log':source.unlink()
            print('Preserved route attempt:',archive,flush=True)
            stage('05b','CHIP_ROUTEFIX_COMMANDS_COMPLETED')
    route_drc=(run/'mynpu/pnr/reports/12_route_drc.rpt').read_text()
    if 'No DRC violations were found'not in route_drc:
        raise RuntimeError('Routing DRC did not converge. Preserve the initial evidence, inspect/repair routing (05b), then resume with --start-stage 06')
    if not antenna_met('12_route'):
        raise RuntimeError('Routing antenna check did not pass; preserve reports and repair before continuing')
    setup,hold=timing('postRoute'),timing('postRoute_hold')
    print('postRoute setup/hold (WNS ns, violating paths):',setup,hold,flush=True)
    stage('06','CHIP_FINISH_COMMANDS_COMPLETED',dict(FLOW_FIX_ROUTE_SETUP=str(int(not timing_met(setup))),FLOW_FIX_ROUTE_HOLD=str(int(not timing_met(hold) or not timing_met(setup)))))
    setup,hold=timing('final_setup'),timing('final_hold')
    print('Final setup/hold (WNS ns, violating paths):',setup,hold,flush=True)
    if not all(timing_met(t)for t in(setup,hold)):raise RuntimeError('Final timing not closed; preserve reports before further changes')
    def final_route_clean():
        path=run/'mynpu/pnr/reports/13_final_drc.rpt'
        return path.is_file()and'No DRC violations were found'in path.read_text()and antenna_met('13_final')
    if int(a.start_stage)<=6:
        for repair_round in range(3):
            if final_route_clean():break
            out=run/'mynpu/pnr'
            archive=out/'attempts'/('auto-finish-route-repair-%02d-%d'%(repair_round+1,time.time_ns()))
            archive.mkdir(parents=True)
            for name in ('13_finished.enc','13_finished.enc.dat'):
                source=out/'checkpoints'/name
                if source.is_dir():shutil.copytree(source,archive/name)
                else:shutil.copy2(source,archive/name)
            for source in (out/'reports').glob('13*'):
                if source.is_file():shutil.copy2(source,archive/source.name)
            for name in ('final_setup','final_hold'):
                shutil.copytree(out/'reports'/name,archive/name)
            for name in ('06_launcher.log','06b_launcher.log'):
                source=out/name
                if source.is_file():
                    with source.open('rb')as inp,gzip.open(archive/(name+'.gz'),'wb')as dest:shutil.copyfileobj(inp,dest)
                    if name=='06b_launcher.log':source.unlink()
            shutil.copy2(run/'scripts/pnr_06b_routefix.tcl',archive/'pnr_06b_routefix.tcl')
            print('Preserved timing-optimized layout:',archive,flush=True)
            stage('06b','CHIP_FINISH_ROUTEFIX_COMMANDS_COMPLETED')
            setup,hold=timing('final_setup'),timing('final_hold')
            print('After final route repair setup/hold:',setup,hold,flush=True)
            if not all(timing_met(t)for t in(setup,hold)):raise RuntimeError('Late route repair changed final timing; preserve reports and re-optimize before export')
    drc=(run/'mynpu/pnr/reports/13_final_drc.rpt').read_text()
    if'No DRC violations were found'not in drc:raise RuntimeError('Final routing DRC needs repair')
    if not antenna_met('13_final'):raise RuntimeError('Final antenna check needs repair')
    stage('07','CHIP_FINAL_EXPORT')
    runner=run/'scripts/frozen_run_stage.sh'
    if not runner.is_file():runner=ROOT/'eda/tsmc180/run_stage.sh'
    subprocess.run(['bash',str(runner),str(run),'audit'],cwd=ROOT,check=True)
if __name__=='__main__':main()
