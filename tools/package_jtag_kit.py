"""Package verified bitstreams and PC runtime assets, without private SRAM IP."""
import argparse,hashlib,json,zipfile
from pathlib import Path
from jtag_host import read_bundle
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'build/lab6-jtag-kit.zip');a=p.parse_args()
    sim=json.loads((ROOT/'docs/lab6-jtag-verification.json').read_text())
    fpga=json.loads((ROOT/'docs/lab6-jtag-fpga.json').read_text())
    assert sim['inferences']==768 and len(sim['records'])==4,'Complete the VCS matrix first'
    files=[ROOT/'tools/jtag_host.py',ROOT/'sw/main_jtag.c',ROOT/'sw/startup.S']
    files+=list((ROOT/'generated/jtag').rglob('*'))
    files += [ROOT/'docs'/n for n in ('lab6-jtag.md','lab6-jtag-fpga.json','lab6-jtag-verification.json')]
    files += [ROOT/'fpga/ego1'/n for n in ('program_jtag.tcl','attach_ft232h.ps1','start_openocd.sh',
      'start_gdb.sh','debug_cpu.sh','ego1_openocd.cfg','sba_helpers.tcl','setup_wsl.sh','setup_lab6_openocd.sh')]
    for record in fpga['records']:
        _,manifest=read_bundle(record['layout'])
        assert manifest['lanes']==record['lanes']and manifest['cache_words']==record['cache_words']
        for name,digest in record['artifacts_sha256'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
            files.append(ROOT/name)
        elf=ROOT/'build/jtag'/record['layout']/'firmware.elf'
        if elf.is_file():files.append(elf)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(a.output,'w',zipfile.ZIP_DEFLATED)as archive:
        archive.writestr('mynpu-lab6/README.txt',
          'Lab6 JTAG runtime kit: see docs/lab6-jtag.md.\n'
          'Both private/shared 4-lane bitstreams and matching PC assets are included.\n'
          'Configure EGo1 using board USB-JTAG; connect external FT232H/J5 for OpenOCD/GDB.\n'
          'Physical FT232H board testing remains separate from the recorded VCS simulations.\n'
          'No proprietary SRAM model or PDK files are included.\n'
          'Full RTL/build source: https://github.com/one-bite-one-pig/mynpu/tree/feature/dual-bank-shared-sram\n')
        for file in dict.fromkeys(files):
            if file.is_file():
                name=file.relative_to(ROOT).as_posix()
                assert 'RA1SHD_2048x32M8.v'not in name and file.suffix not in ('.lib','.lef','.cdl')
                archive.write(file,'mynpu-lab6/'+name)
    print('Runtime kit:',a.output,a.output.stat().st_size,'bytes')
if __name__=='__main__':main()
