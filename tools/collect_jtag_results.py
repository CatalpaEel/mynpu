"""Collect only completed Lab6 VCS logs; never archive the proprietary SRAM model."""
import hashlib,json,re,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    records=[];logs=[]
    for memory in ('fpga','asic'):
        for layout in ('private','shared'):
            folder=ROOT/'build'/('jtag-vcs-%s-%s-v64-b3'%(memory,layout))
            log=folder/'run.log';text=log.read_text(errors='replace')
            matches=re.findall(r'^\[JTAG-SOC\] PASS .+$',text,re.M)
            if len(matches)!=1 or re.search(r'(?m)^(?:Fatal|FATAL|Error|ERROR)(?::|-\[)',text)or'inferences=192'not in matches[0]:
                raise SystemExit('Incomplete/failing test: '+str(log))
            records.append(dict(memory=memory,layout=layout,boots=3,inferences=192,pass_line=matches[0],
                progress=[line for line in text.splitlines()if line.startswith('[JTAG-SOC]')]))
            logs += [log,folder/'compile.log']
    names=['rtl/mynpu_debug_boot.sv','rtl/mynpu_soc_top.sv','sim/tb_soc_jtag.sv',
           'sim/jtag_transaction_driver.svh','sw/main_jtag.c',
           'generated/jtag/private/cpu.hex','generated/jtag/shared/cpu.hex',
           'generated/jtag/private/model.hex','generated/jtag/shared/model.hex','generated/jtag/vectors/mnist.json']
    summary=dict(date='2026-10-17',engine='VCS four-state functional simulation',inferences=768,
      notes='Actual TAP/DMI/SBA, cold load, POR + ndmreset, CPU halt/resume/WFI/IRQ. ASIC uses the private RA1SHD model with timing checks disabled; no PDK signoff. External FT232H board link is a separate test.',
      source_lf_sha256={name:hashlib.sha256((ROOT/name).read_bytes().replace(b'\r\n',b'\n')).hexdigest()for name in names},records=records)
    output=ROOT/'build/lab6-jtag-verification.json';output.write_text(json.dumps(summary,indent=2)+'\n')
    with tarfile.open(ROOT/'build/lab6-jtag-verification-logs.tgz','w:gz')as archive:
        for file in logs+[output]:archive.add(file,arcname=str(file.relative_to(ROOT)))
    print('PASS: four configurations, 12 boots, 768 inferences; archive contains logs only')
if __name__=='__main__':main()
