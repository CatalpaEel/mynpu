"""Compare the optional FPGA CPU RF with the unmodified ASIC CPU RF in VCS."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--seed',type=int,default=20261118)
    a=p.parse_args()
    out=a.out.resolve()
    out.mkdir(parents=True,exist_ok=False)
    reference=REPO/'external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_register_file_ff.sv'
    inputs=[reference,HERE/'cv32e40p_register_file_lutram.sv',HERE/'tb_cpu_rf_lutram.sv']
    hashes={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
    text=reference.read_text()
    old='module cv32e40p_register_file #('
    if text.count(old)!=1:
        raise ValueError('Unexpected reference module declaration')
    (out/'reference_register_file.sv').write_text(text.replace(old,'module reference_register_file #('))
    for src in inputs[1:]:
        shutil.copy2(src,out/src.name)
    result={'passed':False,'seed':a.seed,'checks':0,'source_sha256':hashes,
            'scope':'RTL comparison of the current integer CPU register-file configuration, not full SoC or netlist equivalence'}
    try:
        cmd=['vcs','-full64','-sverilog','-timescale=1ns/1ps',
             'cv32e40p_register_file_lutram.sv','reference_register_file.sv','tb_cpu_rf_lutram.sv',
             '-top','tb_cpu_rf','-o',str(out/'simv')]
        with (out/'compile.log').open('w') as f:
            subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT,check=True)
        with (out/'sim.log').open('w') as f:
            subprocess.run([str(out/'simv'),f'+ntb_random_seed={a.seed}'],cwd=out,
                           stdout=f,stderr=subprocess.STDOUT,check=True)
        log=(out/'sim.log').read_text()
        # Some VCS configurations return zero even after $fatal.
        if 'CPU_RF_PROTO PASS checks=40000 cycles=20000' not in log or 'Fatal:' in log:
            raise RuntimeError('CPU RF comparison failed; inspect sim.log')
        if any(hashlib.sha256(f.read_bytes()).hexdigest()!=hashes[str(f)] for f in inputs):
            raise RuntimeError('Sources changed during simulation')
        result.update(passed=True,checks=40000,cycles=20000)
        print('CPU_RF_EQUIVALENCE PASS checks=40000 cycles=20000')
    finally:
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':
    main()
