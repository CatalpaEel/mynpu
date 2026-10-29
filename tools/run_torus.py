"""VCS functional regressions for the software-controlled 4x4 torus."""
import argparse,hashlib,json,os,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--memory',choices=['fpga','asic'],required=True);p.add_argument('--suite',choices=['unit','soc'],required=True)
 p.add_argument('--assets',type=Path,default=ROOT/'build/torus/assets');p.add_argument('--tap-all',action='store_true')
 p.add_argument('--max-cycles',type=int,default=0,help='Strict inference limit including CPU argmax')
 p.add_argument('--mapped-pe-run',type=Path,help='Unit-test the frozen mapped PE plus current RTL')
 p.add_argument('--cache-words',type=int,choices=[16,32,64],default=32)
 p.add_argument('--tag',default='',help='Separate output directory for A/B runs')
 p.add_argument('--macro-model',type=Path,default=ROOT.parent/'soc_cv32e40p_template_pnr-stu/src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v')
 a=p.parse_args()
 if not re.fullmatch('[A-Za-z0-9_-]*',a.tag):p.error('Invalid tag')
 backend=1 if a.memory=='fpga'else 2
 out=ROOT/'build/torus'/('%s-%s%s'%(a.suite,a.memory,'-tapall'if a.tap_all else'')+('-'+a.tag if a.tag else''));out.mkdir(parents=True,exist_ok=True)
 sources=['cnn_npu_int8/rtl/torus_pe.sv','cnn_npu_int8/rtl/torus_array.sv','cnn_npu_int8/rtl/shape_stream.sv','rtl/mynpu_torus_subsystem.sv','rtl/mynpu_banked_sram.sv','rtl/mynpu_sram_2048x32_fpga.sv']
 top='tb_torus'if a.suite=='unit'else'tb_torus_soc';params=[];plusargs=[]
 if a.suite=='soc':
  sources=['-f','sim/soc.f'];meta=json.loads((a.assets/'manifest.json').read_text());params=['-pvalue+tb_torus_soc.MEM_BACKEND=%d'%backend,'-pvalue+tb_torus_soc.VECTORS=%d'%meta['vectors'],'-pvalue+tb_torus_soc.EXPECT_OVERLAP=%d'%meta.get('overlap',False),'-pvalue+tb_torus_soc.COMPACT_CONFIG=%d'%meta.get('compact_config',False),'-pvalue+tb_torus_soc.CACHE_WORDS=%d'%a.cache_words,'-pvalue+tb_torus_soc.MAX_CYCLES=%d'%a.max_cycles]
  plusargs=['+MODEL_WORDS=%d'%meta.get('model_load_words',1072),'+FOLDER='+str(a.assets.resolve()),'+CPU_WORDS=%d'%((meta['cpu_bytes']+3)//4),'+TAP_ALL=%d'%a.tap_all]
 else:
  params=['-pvalue+tb_torus.CACHE_WORDS=%d'%a.cache_words]
  if backend==2:params+=['+define+ASIC_SRAM']
 if backend==2:sources+=['rtl/mynpu_sram_2048x32_asic.sv',str(a.macro_model.resolve())];plusargs+=['+notimingchecks','+no_notifier']
 if a.mapped_pe_run:
  if a.suite!='unit':p.error('--mapped-pe-run is for PE functional unit checks')
  leaf=a.mapped_pe_run.resolve()/'inputs/mapped_torus_pe.v';wrapper=leaf.with_name('mapped_torus_wrapper.sv')
  std=Path('/home/almalinux/tsmc180/tcb018gbwp7t_290a/TSMCHOME/digital/Front_End/verilog/tcb018gbwp7t_270a/tcb018gbwp7t.v')
  sources=sources[1:]+[str(leaf),str(wrapper),str(std)]
  params+=['+define+FUNCTIONAL'];plusargs+=['+nospecify','+notimingchecks','+no_notifier']
 sources+=['sim/'+top+'.sv']
 files=[f for d in ['rtl','cnn_npu_int8/rtl','sw/torus']for f in(ROOT/d).glob('*')if f.suffix in ['.sv','.v','.c','.h','.S','.ld']]+[ROOT/'sim'/ (top+'.sv'),ROOT/'sim/soc.f',ROOT/'sim/db_jtag_tasks.svh']
 if a.suite=='soc':files+=list(a.assets.glob('*.hex'))+list(a.assets.glob('*.h'))+list(a.assets.glob('*.S'))+[a.assets/'manifest.json']
 if a.mapped_pe_run:files += [leaf,wrapper,std]
 hashes={os.path.relpath(f.resolve(),ROOT):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
 (out/'inputs.json').write_text(json.dumps(hashes,indent=2)+'\n')
 binary=out/'simv';cmd=['vcs','-full64','-sverilog','-assert','svaext','-timescale=1ns/1ps','+define+SYNTHESIS','-Mdir='+str(out/'csrc')]+params+sources+['-top',top,'-o',str(binary)]
 with(out/'compile.log').open('w')as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
 if r.returncode:raise SystemExit((out/'compile.log').read_text(errors='replace')[-7000:])
 with(out/'run.log').open('w')as log:r=subprocess.run([str(binary)]+plusargs,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
 log=(out/'run.log').read_text(errors='replace');mark='TORUS-PASS'if a.suite=='unit'else'TORUS-SOC-PASS'
 changed=[f for f,s in hashes.items()if hashlib.sha256((ROOT/f).read_bytes()).hexdigest()!=s]
 evidence=[s for s in log.splitlines()if s.startswith('TORUS')]
 result=dict(max_cycles=a.max_cycles,mapped_pe_run=str(a.mapped_pe_run)if a.mapped_pe_run else None,cache_words=a.cache_words,passed=r.returncode==0 and mark in log and'Fatal:'not in log and not changed,memory=a.memory,suite=a.suite,evidence=evidence,rtl_sha256=hashes,changed_during_run=changed,scope='VCS functional simulation; ASIC timing checks disabled; no physical area or frequency result')
 if a.suite=='soc':result['assets']=meta
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('\n'.join(evidence));print(out)
 if not result['passed']:raise SystemExit(log[-5000:]+str(changed))
if __name__=='__main__':main()
