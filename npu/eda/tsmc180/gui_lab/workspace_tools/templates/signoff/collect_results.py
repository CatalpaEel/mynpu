from pathlib import Path
import json,re,hashlib,sys,importlib.util
R=Path(__file__).resolve().parents[1];ROOT=R.parent.parent
spec=importlib.util.spec_from_file_location('lab5_checks',ROOT/'mynpu-softpe/npu/eda/tsmc180/collect_lab5.py');lib=importlib.util.module_from_spec(spec);spec.loader.exec_module(lib)
def sha(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
 m=json.loads((R/'manifest.json').read_text());pnr=Path(m['source_pnr_run']);assert sha(pnr/'manifest.json')==m['source_pnr_manifest_sha256']
 for p,h in m['input_sha256'].items():assert sha(p)==h and sha(R/'inputs'/Path(p).name)==h
 drc=lib.checks(R/'drc_post/summary.rpt');remaining=[row for row in drc['nonzero'] if not row['rule'].startswith(('DRM','ESD','MOM','LUP'))];drc.update(course_exclusions=['DRM','ESD','MOM','LUP'],remaining_after_course_exclusions=remaining,course_passed=not remaining)
 strict=lib.lvs(R/'lvs_strict/report.rpt');lvs=lib.lvs(R/'lvs/report.rpt');erc=lib.checks(R/'lvs/erc.summary',erc=True);ant=lib.checks(R/'antenna/summary.rpt');wb=lib.checks(R/'wb/summary.rpt')
 txt=(R/'outputs/sealring_poc.txt').read_text();bounds=list(map(float,re.findall(r'-?\d+\.\d+',txt.splitlines()[0])));assert len(bounds)==4,bounds
 outer=[bounds[2]-bounds[0],bounds[3]-bounds[1]];dims={'die_um':m['die_um'],'sealring_bbox_um':bounds,'sealring_outer_um':outer,'course_die_limit_um':[1950,1950],'course_ring_limit_um':[1980,1980]};dims['passed']=all(x<=1950 for x in m['die_um']) and all(x<=1980+1e-6 for x in outer)
 names=['v2lvs','streamin_exact','build_layout','pre_streamout','drc_pre','dummy_metal','dummy_od_po','merge','init_final','final_streamin','lvs_strict','lvs_teaching','drc_post','antenna','wb'];stages={}
 for name in names:
  j=json.loads((R/'logs'/f'{name}.json').read_text());assert not j.get('changed_during_run'),name
  for p,h in j['output_sha256'].items():assert sha(p)==h,(name,p)
  stages[name]=j
 complete=all(j['command_completed'] for j in stages.values());known={'mnpg':(4,832),'floating.nxwell_float':(1,72),'npvss49':(1,72),'floating.psub_float':(1,1)};known_erc={row['rule']:(row['hierarchical'],row['expanded']) for row in erc['nonzero']}==known
 include=re.findall(r'^\.INCLUDE "([^"]+)"',(R/'cdl/mynpu_asic_top.cdl').read_text(),re.M);assert len(include)==3
 assert lvs['full_property_checks']==605 and lvs['resistor_tolerance']==['3.48'] and lvs['split_gates']
 report={'run':str(R),'source_pnr_run':str(pnr),'flow_commands_completed':complete,'dimensions':dims,'drc':drc,'lvs_strict':strict,'lvs_lab5_tolerance':lvs,'erc':{**erc,'matches_documented_io_outer_patterns':known_erc,'clean':erc['expanded_results']==0},'antenna':ant,'wire_bond':wb,'stages':stages,'course_checks_except_erc_review_passed':complete and dims['passed'] and drc['course_passed'] and lvs['correct'] and ant['expanded_results']==0 and wb['expanded_results']==0,'course_acceptance_passed':False,'foundry_signoff_passed':False,'remaining_actions':['Review retained ERC IO/outer-substrate findings with the course/foundry owner.','Strict IO PR resistor property mismatch is retained; teaching LVS uses documented 3.48 percent tolerance.','No postDummy PEX/STA or multi-corner/IR/EM foundry signoff is implied.'],'final_input_sha256':{str(p):sha(p) for p in [R/'outputs/mynpu_asic_top_postDummy.gds',R/'cdl/mynpu_asic_top.cdl']},'source_libraries_sha256':{p:sha(p) for p in include},'script_sha256':{p.name:sha(p) for p in (R/'scripts').iterdir() if p.is_file()},'reference_sha256':m['reference_sha256']}
 (R/'outputs/signoff_validation.json').write_text(json.dumps(report,indent=2)+'\n');out=ROOT/'mynpu-softpe/npu/reports/lab5_main53655b5_20261118_r1_validation.json';out.write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:report[k] for k in ['flow_commands_completed','dimensions','course_checks_except_erc_review_passed','course_acceptance_passed','foundry_signoff_passed']},indent=2));print(out)
if __name__=='__main__':main()
