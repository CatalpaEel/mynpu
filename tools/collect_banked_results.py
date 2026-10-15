"""Collect reproducible VCS PASS records and logs, excluding SRAM model/binaries."""
import argparse,hashlib,json,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--seeds',default='8675314,8675313,8675310,8675309,424242');a=p.parse_args()
    seeds=a.seeds.split(',');records=[];files=[]
    for d in sorted((ROOT/'build').iterdir()):
        if not d.is_dir()or not any(d.name.endswith('-s'+s)for s in seeds):continue
        if not(d.name.startswith('db-')or d.name.startswith('sp-')):continue
        if d.name.startswith('sp-')and not(d.name.endswith('-s8675309')and'-soc-'in d.name):continue
        log=d/'run.log'
        if not log.is_file():continue
        text=log.read_text(errors='replace');passes=[line for line in text.splitlines()if'] PASS'in line]
        if not passes or'Fatal:'in text:raise SystemExit('Incomplete/failing regression: '+str(log))
        records.append(dict(directory=str(d.relative_to(ROOT)),pass_lines=passes,
            profiles=[line for line in text.splitlines()if line.startswith('[DB-PROFILE]')]))
        files += [f for f in (log,d/'compile.log')if f.is_file()]
    sources=['cnn_npu_int8/rtl/cnn_npu_banked.sv','rtl/mynpu_banked_sram.sv',
             'rtl/mynpu_shared_subsystem.sv','rtl/mynpu_axi_shared.sv','rtl/mynpu_soc_top.sv']
    result=dict(date='2026-10-15',current_source_sha256={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest()for n in sources},
                notes='Per-directory seeds and configurations retained. No timing checks/PDK signoff. Cache sweep 424242 predates address-register timing optimization; cycles preserved by final c1/c32 checks.',records=records)
    output=ROOT/'build/dual-bank-verification.json';output.write_text(json.dumps(result,indent=2)+'\n')
    with tarfile.open(str(ROOT/'build/dual-bank-verification-logs.tgz'),'w:gz')as archive:
        for f in files+[output]:archive.add(str(f),arcname=str(f.relative_to(ROOT)))
    print('Verified PASS records:',len(records),'logs archived without private macro or simulator binaries')
if __name__=='__main__':main()
