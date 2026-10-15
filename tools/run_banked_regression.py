"""VCS functional regressions for the shared two-macro ASIC/FPGA architecture."""
import argparse,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--memory',choices=['asic','fpga'],required=True)
    p.add_argument('--suite',choices=['fixed','random','edges','fabric','axi','soc','stream','preinit'],default='fixed')
    p.add_argument('--macro-model',default='/tmp/mynpu-vcs/RA1SHD_2048x32M8.v')
    p.add_argument('--lanes',type=int,choices=[1,2,4,8],default=4)
    p.add_argument('--cache-words',type=int,default=1)
    p.add_argument('--runs',type=int,default=100);p.add_argument('--vectors',type=int,default=64)
    p.add_argument('--seed',type=int,default=271828);a=p.parse_args()
    if a.runs<1 or a.vectors<1 or a.cache_words<1 or a.cache_words&(a.cache_words-1):
        p.error('positive runs/vectors and a power-of-two cache size required')
    if a.memory=='asic' and not Path(a.macro_model).is_file():p.error('private SRAM macro model not found')
    if a.suite=='preinit' and a.memory!='fpga':p.error('preinit uses FPGA BRAM power-up images; use soc for ASIC SBA cold loading')
    backend=2 if a.memory=='asic' else 1
    top={'fixed':'tb_npu_banked','random':'tb_npu_banked_random','edges':'tb_npu_banked_edges','fabric':'tb_banked_fabric','axi':'tb_axi_shared','soc':'tb_soc_banked','stream':'tb_soc_banked','preinit':'tb_soc_banked_preinit'}[a.suite]
    build=ROOT/'build'/('db-%s-l%d-c%d-%s-s%d'%(a.memory,a.lanes,a.cache_words,a.suite,a.seed));build.mkdir(parents=True,exist_ok=True)
    if a.suite in ('soc','stream','axi','preinit'):sources=['-f','sim/soc.f']
    else:sources=['rtl/mynpu_sram_2048x32_fpga.sv','rtl/mynpu_banked_sram.sv',
         'cnn_npu_int8/rtl/cnn_npu_lane_mac.sv','cnn_npu_int8/rtl/cnn_npu_banked.sv','rtl/mynpu_shared_subsystem.sv']
    if backend==2:sources+=['rtl/mynpu_sram_2048x32_asic.sv',a.macro_model]
    params={'MEM_BACKEND':backend}
    if a.suite=='preinit':params={'LANES':a.lanes,'ACT_CACHE_WORDS':a.cache_words}
    if a.suite in ('fixed','random','edges','soc','stream'):params.update(LANES=a.lanes,ACT_CACHE_WORDS=a.cache_words)
    if a.suite=='fixed':params.update(RUNS=a.runs,HOST_TRAFFIC=0 if a.runs==1 else 1)
    if a.suite=='random':params['CASES']=a.runs
    if a.suite in ('soc','stream'):params.update(STREAM=(a.suite=='stream')*1,VECTORS=a.vectors)
    binary=build/'simv'
    cmd=['vcs','-full64','-sverilog','-assert','svaext','-timescale=1ns/1ps','+define+SYNTHESIS',
      '-Mdir='+str(build/'csrc')]+sources+['sim/'+top+'.sv','-top',top]+['-pvalue+%s.%s=%s'%(top,k,v)for k,v in params.items()]+['-o',str(binary)]
    with(build/'compile.log').open('w')as log:r=subprocess.run(cmd,cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT)
    if r.returncode:raise SystemExit((build/'compile.log').read_text(errors='replace')[-12000:])
    cmd=[str(binary),'+ntb_random_seed=%d'%a.seed]+(['+notimingchecks','+no_notifier']if backend==2 else [])
    with(build/'run.log').open('w')as log:r=subprocess.run(cmd,cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT)
    text=(build/'run.log').read_text(errors='replace')
    for line in text.splitlines():
        if line.startswith('[')or'Fatal:'in line:print(line,flush=True)
    if r.returncode or'Fatal:'in text or'] PASS'not in text:raise SystemExit(text[-8000:])
    print('Logs:',build,flush=True)
if __name__=='__main__':main()
