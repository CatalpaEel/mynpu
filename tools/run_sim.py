"""Run the complete SoC test with VCS; XSim is an experimental fallback.

Vivado 2023.2 XSim rejects default disable iff in the unmodified lab3 AXI RTL.
The supported/validated backend is VCS.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def simulator_tool(name):
    return shutil.which(name) or name

def run(command, log):
    print(' '.join(map(str,command)), flush=True)
    if os.name == 'nt' and str(command[0]).lower().endswith('.bat'):
        # Preserve NAME=VALUE through Vivado's batch argument parser.
        launcher=log.with_suffix('.cmd')
        launcher.write_text('@echo off\ncall '+ ' '.join('"'+str(a)+'"' for a in command)+'\n')
        command=['cmd','/d','/c',str(launcher)]
    with log.open('w') as f:
        p = subprocess.run(command, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    output=log.read_text(errors='replace')
    # Vivado batch launchers may return zero even when elaboration failed.
    if p.returncode or '\nERROR:' in output or '\nError-[' in output:
        print(output[-14000:])
        raise SystemExit(p.returncode or 1)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--backend',choices=['xsim','vcs'],default='vcs')
    ap.add_argument('--layout',choices=['8k','16k'],default='8k')
    ap.add_argument('--lanes',type=int,default=8)
    ap.add_argument('--stress',action='store_true',
                    help='exercise reset, SBA traffic, invalid NPU config, and halt/resume')
    ap.add_argument('--stress-sba-words',type=int,default=64)
    ap.add_argument('--stress-halt-rounds',type=int,default=3)
    args=ap.parse_args()
    suffix = '-stress' if args.stress else ''
    build=ROOT/'build'/f'{args.backend}-{args.layout}-{args.lanes}{suffix}'
    build.mkdir(parents=True,exist_ok=True)
    size=8192 if args.layout=='8k' else 16384
    if args.backend=='vcs':
        binary=(build/'simv').as_posix()
        stress_params = []
        if args.stress:
            stress_params = [
                '-pvalue+tb_mynpu_soc.STRESS_MODE=1',
                f'-pvalue+tb_mynpu_soc.STRESS_SBA_WORDS={args.stress_sba_words}',
                f'-pvalue+tb_mynpu_soc.STRESS_HALT_ROUNDS={args.stress_halt_rounds}',
            ]
        run(['vcs','-full64','-sverilog','-assert','svaext','-timescale=1ns/1ps','+define+SYNTHESIS','-f','sim/soc.f',
             'sim/tb_mynpu_soc.sv','-top','tb_mynpu_soc',f'-pvalue+tb_mynpu_soc.LANES={args.lanes}',
             f'-pvalue+tb_mynpu_soc.NPU_SRAM_BYTES={size}',*stress_params,'-o',binary],build/'compile.log')
        run([binary],build/'run.log')
    else:
        files=[]; includes=[]
        for line in (ROOT/'sim/soc.f').read_text().splitlines():
            if line.startswith('+incdir+'):
                includes+=['-i',line[len('+incdir+'):]]
            elif line: files.append(line)
        run([simulator_tool('xvlog'),'--sv','--relax','-d','SYNTHESIS',*includes,*files,
             'sim/tb_mynpu_soc.sv'],build/'compile.log')
        snapshot=f'soc_{args.layout}_{args.lanes}{suffix}'
        stress_generics = []
        if args.stress:
            stress_generics = ['--generic_top','STRESS_MODE=1',
                               '--generic_top',f'STRESS_SBA_WORDS={args.stress_sba_words}',
                               '--generic_top',f'STRESS_HALT_ROUNDS={args.stress_halt_rounds}']
        run([simulator_tool('xelab'),'--relax','--debug','typical',
             '--generic_top',f'LANES={args.lanes}','--generic_top',f'NPU_SRAM_BYTES={size}',*stress_generics,
             'tb_mynpu_soc','-s',snapshot],build/'elaborate.log')
        run([simulator_tool('xsim'),snapshot,'--runall'],build/'run.log')
    output=(build/'run.log').read_text(errors='replace')
    print(output[-7000:])
    if '[SOC] PASS' not in output:
        raise SystemExit('Simulation did not report PASS')

if __name__=='__main__': main()
