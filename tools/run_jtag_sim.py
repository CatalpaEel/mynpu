"""Run Lab6 cold-load SoC regression with VCS; local XSIM is experimental."""
import argparse,os,re,shutil,subprocess
from pathlib import Path
from run_sim import run
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--backend',choices=['xsim','vcs','verilator'],default='vcs')
    p.add_argument('--memory',choices=['fpga','asic'],required=True);p.add_argument('--layout',choices=['private','shared'],required=True)
    p.add_argument('--vectors',type=int,default=64);p.add_argument('--boots',type=int,default=3)
    p.add_argument('--vivado-bin',type=Path,default=Path('E:/Vivado/2023.2/bin'))
    p.add_argument('--macro-model',type=Path,default=ROOT/'build/asic_macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.v');a=p.parse_args()
    if a.vectors<1 or a.boots<1:p.error('positive vectors and boots required')
    if a.backend=='verilator'and not all(shutil.which(n)for n in('verilator','clang++','g++')):
        p.error('optional Verilator backend requires Linux/WSL verilator, clang++ and g++')
    mem=2 if a.memory=='asic'else 1
    if mem==2 and not a.macro_model.is_file():p.error('private macro model required')
    build=ROOT/'build'/('jtag-%s-%s-%s-v%d-b%d'%(a.backend,a.memory,a.layout,a.vectors,a.boots));build.mkdir(parents=True,exist_ok=True)
    params=dict(MEM_BACKEND=mem,SHARED=int(a.layout=='shared'),VECTORS=a.vectors,BOOT_ROUNDS=a.boots)
    files=[];includes=[]
    for line in(ROOT/'sim/soc.f').read_text().splitlines():
        if line.startswith('+incdir+'):includes+=['-i',line[8:]]
        elif line:files.append(line)
    if mem==2:files+=['rtl/mynpu_sram_2048x32_asic.sv',str(a.macro_model)]
    files+=['sim/tb_soc_jtag.sv']
    if a.backend=='xsim':
        def tool(name):return str(a.vivado_bin/(name+'.bat' if os.name=='nt'else name))
        # VERILATOR skips only unsupported imported assertions, preserving lab3 bytes.
        run([tool('xvlog'),'--sv','--relax','-d','SYNTHESIS','-d','VERILATOR',*includes,*files],build/'compile.log')
        snapshot='jtag_'+a.memory+'_'+a.layout+'_'+str(a.vectors)+'_'+str(a.boots)
        run([tool('xelab'),'--relax','--debug','off','--notimingchecks',
          *[v for k,n in params.items()for v in('--generic_top',k+'='+str(n))],
          'tb_soc_jtag','-s',snapshot],build/'elaborate.log')
        run([tool('xsim'),snapshot,'--runall'],build/'run.log')
    elif a.backend=='verilator':
        binary=build/'simv'
        libgcc=subprocess.check_output(['g++','-print-libgcc-file-name'],text=True).strip()
        run(['verilator','--binary','--timing','--assert','--compiler','clang','-MAKEFLAGS','CXX=clang++',
          '-CFLAGS','--gcc-install-dir='+str(Path(libgcc).parent)+' -std=c++20',
          '-Wno-fatal','-Wno-BLKANDNBLK','-j','2','--top-module','tb_soc_jtag',
          '-Mdir',str(build/'obj-worker'),'+define+SYNTHESIS','-f','sim/soc.f',
          *(['rtl/mynpu_sram_2048x32_asic.sv',str(a.macro_model)]if mem==2 else []),'sim/tb_soc_jtag.sv',
          *['-G%s=%d'%(k,n)for k,n in params.items()],'-o',str(binary)],build/'compile.log')
        run(['stdbuf','-oL',str(binary)],build/'run.log')
    else:
        binary=build/'simv'
        run(['vcs','-full64','-sverilog','-assert','svaext','-timescale=1ns/1ps','+define+SYNTHESIS','-f','sim/soc.f',
          '-Mdir='+str(build/'csrc'),
          *(['rtl/mynpu_sram_2048x32_asic.sv',str(a.macro_model)]if mem==2 else []),'sim/tb_soc_jtag.sv',
          '-top','tb_soc_jtag',*['-pvalue+tb_soc_jtag.%s=%d'%(k,n)for k,n in params.items()],'-o',str(binary)],build/'compile.log')
        run(['stdbuf','-oL',str(binary),'+notimingchecks','+no_notifier'],build/'run.log')
    output=(build/'run.log').read_text(errors='replace')
    print(output[-6500:])
    if '[JTAG-SOC] PASS'not in output or re.search(r'(?m)^(?:Fatal|FATAL|Error|ERROR)(?::|-\[)',output):
        raise SystemExit('SoC regression did not pass')
if __name__=='__main__':main()
