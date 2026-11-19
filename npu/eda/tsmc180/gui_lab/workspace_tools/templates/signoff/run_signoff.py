"""Run frozen Lab5 steps only after the 1950um PNR export is complete."""
from pathlib import Path
import subprocess,json,hashlib,gzip,shutil,concurrent.futures
R=Path(__file__).resolve().parents[1];ROOT=R.parent.parent;PNR=ROOT/'eda-runs/20261118-main53655b5-fullchip-r1';W=R/'workspace'
CAL=Path('/opt/eda/Mentor/aok_cal_2022.3_17.8/bin');PDK=Path('/home/almalinux/tsmc180');MAC=ROOT/'soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8'
MAP=PDK/'t018cmsp007k3_1_3a/tsmc18mm_1.8v_3.3v_T-018-CM-SP-007-K3_IC61_bsim4.5_pdk_v1.3a_20170119/PDK/tsmc18/tsmc18.layermap'
def sha(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def step(name,cmd,cwd,marker=None,markerfile=None,outputs=()):
 record=R/'logs'/f'{name}.json';log=R/'logs'/f'{name}-launcher.log'
 if record.exists():
  old=json.loads(record.read_text())
  if old['command_completed'] and all(Path(p).is_file() and sha(p)==h for p,h in old['output_sha256'].items()):print(name,'CACHED',flush=True);return
  raise RuntimeError('Incomplete prior attempt, inspect before retry: '+str(record))
 tracked=[Path(a) for a in cmd[1:] if str(a).startswith('/') and Path(a).is_file()]
 inputs={str(p):sha(p) for p in tracked}
 with log.open('w') as f:rc=subprocess.run([str(x) for x in cmd],cwd=cwd,stdout=f,stderr=subprocess.STDOUT).returncode
 changed=[p for p,h in inputs.items() if sha(p)!=h]
 text=Path(markerfile or log).read_text(errors='replace');ok=not changed and rc==0 and (marker is None or marker in text) and all(Path(p).is_file() and Path(p).stat().st_size for p in outputs)
 record.write_text(json.dumps({'command':[str(x) for x in cmd],'cwd':str(cwd),'returncode':rc,'input_sha256':inputs,'changed_during_run':changed,'command_completed':ok,'output_sha256':{str(p):sha(p) for p in outputs if Path(p).is_file()},'launcher_log_sha256':sha(log)},indent=2)+'\n');print(name,'COMPLETED' if ok else 'FAILED',flush=True)
 if not ok:raise RuntimeError(name+' failed; '+str(log))
def main():
 ready=json.loads((PNR/'signoff_input_ready.json').read_text())
 for p,h in ready['input_sha256'].items():assert sha(p)==h
 assert 'No DRC violations were found' in (PNR/'mynpu/pnr/reports/13_final_drc.rpt').read_text()
 files=[PNR/'mynpu/pnr/outputs/final'/name for name in ['mynpu_asic_top.gds.gz','mynpu_asic_top.flat_lvs.v','mynpu_asic_top.def']]
 manifest=R/'manifest.json'
 if not manifest.exists():
  for p in files:shutil.copy2(p,R/'inputs'/p.name)
  with gzip.open(R/'inputs/mynpu_asic_top.gds.gz','rb') as f,(R/'inputs/mynpu_asic_top.gds').open('wb') as o:shutil.copyfileobj(f,o)
  shutil.copy2(ROOT/'eda-runs/20261109-lab5-all4/cdl/sram_ports.v',R/'inputs/RA1SHD_2048x32M8_lvs_ports.v')
  manifest.write_text(json.dumps({'source_pnr_run':str(PNR),'source_pnr_manifest_sha256':sha(PNR/'manifest.json'),'input_sha256':{str(p):sha(p) for p in files},'reference_sha256':{p.name:sha(p) for p in (R/'reference').iterdir() if p.is_file()},'guide':'https://full-stack-ai-chip.tianyuj.com/lab-5/','die_um':[1950,1950],'signal_pads':9,'scope':'Fresh full-chip signoff input; no SRAM Box, no supply merging, no shared PDK edits'},indent=2)+'\n')
 else:
  for p,h in json.loads(manifest.read_text())['input_sha256'].items():assert sha(p)==h
 std=PDK/'tcb018gbwp7t_290a/TSMCHOME/digital/Back_End/spice/tcb018gbwp7t_270a/tcb018gbwp7t_270a.spi';io=PDK/'tpd018nv_280a/TSMCHOME/digital/Back_End/spice/tpd018nv_270a/tpd018nv_1_2.spi'
 step('v2lvs',[CAL/'v2lvs','-v',R/'inputs/mynpu_asic_top.flat_lvs.v','-lsr',std,'-lsr',io,'-l',R/'inputs/RA1SHD_2048x32M8_lvs_ports.v','-s',std,'-s',io,'-s',MAC/'RA1SHD_2048x32M8.cdl','-s0','VSS','-s1','VDD','-o',R/'cdl/mynpu_asic_top.cdl'],R/'cdl','Design Conversion completed',outputs=[R/'cdl/mynpu_asic_top.cdl'])
 step('streamin_exact',['strmin','-library','mynpu_lab5_exact','-strmFile',R/'inputs/mynpu_asic_top.gds','-topCell','mynpu_asic_top','-view','layout','-case','Preserve','-layerMap',MAP,'-attachTechFileOfLib','mynpu_tech2000','-dbuPerUU','2000','-reportPrecisionLoss','-logFile',R/'logs/streamin_exact.log'],W,"Translation completed. '0' error",R/'logs/streamin_exact.log')
 step('build_layout',['virtuoso','-nograph','-nocdsinit','-restore',R/'scripts/build_layout.il','-log',R/'logs/build_layout.log'],W,'LAB5_BUILD_1950_LAYOUT_PASS',outputs=[R/'outputs/sealring_poc.txt'])
 step('pre_streamout',['strmout','-library','mynpu_lab5_exact','-strmFile',R/'outputs/mynpu_asic_top_preDummy.gds','-topCell','mynpu_asic_top','-view','layout','-case','Preserve','-techLib','mynpu_tech2000','-layerMap',MAP,'-logFile',R/'logs/pre_streamout.log'],W,"Translation completed. '0' error",R/'logs/pre_streamout.log',[R/'outputs/mynpu_asic_top_preDummy.gds'])
 step('drc_pre',[CAL/'calibre','-drc','-hier','-turbo','8',R/'rules/pre.drc'],R/'drc_pre','CALIBRE::DRC-H COMPLETED',outputs=[R/'drc_pre/summary.rpt'])
 for folder in ['metal','od']:(R/'dummy'/folder).mkdir(exist_ok=True)
 def fill(kind):
  metal=kind=='metal';name='dummy_metal' if metal else 'dummy_od_po';rule=R/'dummy'/('Dummy_Metal_Calibre_0.18um.215a' if metal else 'Dummy_OD_PO_Calibre_0.18um.210a');out=R/'dummy'/kind/('DM.gds' if metal else 'DOD.gds')
  step(name,[CAL/'calibre','-drc','-hier','-hyper','-turbo','4',rule],R/'dummy'/kind,'CALIBRE::DRC-H COMPLETED',outputs=[out])
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(fill,['metal','od']))
 step('merge',[CAL/'calibredrv','-a','layout','filemerge','-in',R/'outputs/mynpu_asic_top_preDummy.gds','-in',R/'dummy/od/DOD.gds','-in',R/'dummy/metal/DM.gds','-rename','-createtop','mynpu_asic_top_postDummy','-out',R/'outputs/mynpu_asic_top_postDummy.gds'],W,'Merge completed successfully',outputs=[R/'outputs/mynpu_asic_top_postDummy.gds'])
 step('init_final',['virtuoso','-nograph','-nocdsinit','-restore',R/'scripts/init_final.il','-log',R/'logs/init_final.log'],W)
 step('final_streamin',['strmin','-library','mynpu_lab5_final','-strmFile',R/'outputs/mynpu_asic_top_postDummy.gds','-topCell','mynpu_asic_top_postDummy','-view','layout','-case','Preserve','-layerMap',MAP,'-attachTechFileOfLib','mynpu_tech2000','-dbuPerUU','2000','-reportPrecisionLoss','-logFile',R/'logs/final_streamin.log'],W,"Translation completed. '0' error",R/'logs/final_streamin.log')
 # Independent checks share one immutable final GDS and have separate directories.
 jobs=[('lvs_strict','lvs_strict','post_strict.lvs',True),('lvs_teaching','lvs','post.lvs',True),('drc_post','drc_post','post.drc',False),('antenna','antenna','post.ant',False),('wb','wb','post.wb',False)]
 def verify(job):
  name,folder,rule,is_lvs=job
  if is_lvs:
   step(name,[CAL/'calibre','-lvs','-hier','-turbo','4','-spice','layout.sp',R/'rules'/rule],R/folder,'CALIBRE::LVS/xRC COMPLETED',outputs=[R/folder/'report.rpt',R/folder/'erc.summary'])
  else:
   step(name,[CAL/'calibre','-drc','-hier','-turbo','8',R/'rules'/rule],R/folder,'CALIBRE::DRC-H COMPLETED',outputs=[R/folder/'summary.rpt'])
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(verify,jobs))
 (R/'outputs/final_inputs.sha256').write_text(''.join(f'{sha(p)}  {p}\n' for p in [R/'outputs/mynpu_asic_top_postDummy.gds',R/'cdl/mynpu_asic_top.cdl']))
 print('LAB5_RF1R1W_DIE1950_COMMANDS_COMPLETED',flush=True)
if __name__=='__main__':main()
