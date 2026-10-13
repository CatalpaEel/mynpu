"""Reproduce ASIC-macro or FPGA-BRAM functional regressions with VCS.

Run from a Linux host with VCS. ASIC runs require the private course SRAM
model and deliberately disable timing checks, as agreed for this task.
"""
import argparse
import subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--memory',choices=['asic','fpga'],required=True)
    p.add_argument('--macro-model',type=Path)
    p.add_argument('--lanes',type=int,choices=[1,2,4,8],default=4)
    p.add_argument('--suite',choices=['fixed','edges','random','mnist','soc','stream'],required=True)
    p.add_argument('--runs',type=int,default=100)
    p.add_argument('--cases',type=int,default=200)
    p.add_argument('--vectors',type=int,default=64)
    p.add_argument('--seed',type=int,default=14596)
    args=p.parse_args()
    mem=2 if args.memory=='asic' else 1
    build=ROOT/'build'/f'sp-{args.memory}-l{args.lanes}-{args.suite}-s{args.seed}'
    build.mkdir(parents=True,exist_ok=True)
    if mem==2 and (args.macro_model is None or not args.macro_model.is_file()):
        p.error('ASIC requires --macro-model /path/to/RA1SHD_2048x32M8.v')
    params={}
    if args.suite in ('soc','stream'):
        sources=['-f','sim/soc.f']
        if args.suite=='soc':
            top='tb_mynpu_soc_asic_stress' if mem==2 else 'tb_mynpu_soc_fpga'
            params={'NPU_LANES':args.lanes,'BOOT_ROUNDS':3}
            if mem==2: params.update(SBA_WORDS=64,HALT_ROUNDS=3,CONTENTION_ROUNDS=128)
        else:
            top='tb_mynpu_soc_stream';params={'LANES':args.lanes,'MEM_BACKEND':mem,'VECTORS':args.vectors}
    else:
        sources=['rtl/mynpu_sram_2048x32_fpga.sv','cnn_npu_int8/rtl/cnn_npu_top.sv',
                 'cnn_npu_int8/rtl/cnn_npu_sp_top.sv','cnn_npu_int8/rtl/cnn_npu_lane_mac.sv','cnn_npu_int8/rtl/cnn_npu_sp_lanes.sv',
                 'cnn_npu_int8/rtl/cnn_npu_subsystem.sv']
        top={'fixed':'tb_cnn_npu_sp','edges':'tb_cnn_npu_sp_edges',
             'random':'tb_cnn_npu_vector_stress','mnist':'tb_cnn_npu_mnist'}[args.suite]
        params={'LANES':args.lanes,'MEM_BACKEND':mem}
        if args.suite=='fixed': params['RUNS']=args.runs
        if args.suite=='random': params['CASES']=args.cases
        if args.suite=='mnist': params['VECTORS']=args.vectors
    if mem==2:sources+=['rtl/mynpu_sram_2048x32_asic.sv',str(args.macro_model.resolve())]
    if args.suite=='edges' and args.lanes==1:sources+=['+define+NPU_LEGACY_SCALAR']
    binary=build/'simv'
    command=['vcs','-full64','-sverilog','-assert','svaext','-timescale=1ns/1ps','+define+SYNTHESIS',
             f'-Mdir={build}/csrc',*sources,f'sim/{top}.sv','-top',top,
             *[f'-pvalue+{top}.{k}={v}' for k,v in params.items()],'-o',str(binary)]
    with (build/'compile.log').open('w') as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit((build/'compile.log').read_text(errors='replace')[-12000:])
    command=[str(binary),f'+ntb_random_seed={args.seed}']
    if mem==2:command+=['+notimingchecks','+no_notifier']
    with (build/'run.log').open('w') as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    text=(build/'run.log').read_text(errors='replace')
    for line in text.splitlines():
        if line.startswith('[') or 'Fatal:' in line:print(line,flush=True)
    if result.returncode or 'Fatal:' in text or '] PASS' not in text:
        print(text[-5000:],flush=True)
        raise SystemExit(f'Regression failed: {build}/run.log')
    print(f'Logs: {build}',flush=True)
if __name__=='__main__':main()
