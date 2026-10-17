"""Build Lab6 CPU streaming firmware and separate/shared SBA load manifests."""
import argparse, hashlib, json, shutil, struct, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--gcc',default='riscv64-unknown-elf-gcc')
    p.add_argument('--objcopy');p.add_argument('--lanes',type=int,choices=[2,4,8],default=4)
    p.add_argument('--cache-words',type=int,default=1);a=p.parse_args()
    if a.cache_words<1 or a.cache_words&(a.cache_words-1):p.error('cache words must be a positive power of two')
    gcc=shutil.which(a.gcc) or a.gcc
    if not Path(gcc).is_file():
        local=ROOT.parent/'riscv-tool/usr/bin/riscv64-unknown-elf-gcc'
        if local.is_file():gcc=str(local)
    objcopy=a.objcopy or str(Path(gcc).with_name(Path(gcc).name.replace('gcc','objcopy')))
    for layout in ('private','shared'):
        out=ROOT/'generated/jtag'/layout;out.mkdir(parents=True,exist_ok=True)
        build=ROOT/'build/jtag'/layout;build.mkdir(parents=True,exist_ok=True)
        if layout=='shared':
            source=ROOT/'generated/dual-bank'
            meta=json.loads((source/'golden.json').read_text())
            memory=struct.pack('<4096I',*[int(v,16) for v in(source/'model_word.hex').read_text().split()])
            begin,end=meta['parameter_base'],meta['model_load_end']
        else:
            source=ROOT/'cnn_npu_int8/generated/8k-p4'
            meta=json.loads((source/'golden.json').read_text())
            memory=bytes(int(v,16) for v in(source/'cnn_npu_mem.hex').read_text().split())
            begin,end=0,len(memory)
        output=struct.unpack_from('<I',memory,meta['descriptor_base']+5*36+4)[0]
        build_id=0x4a541000 | (0x100 if layout=='shared' else 0) | a.lanes
        header=''.join('#define %s %du\n'%(k,v) for k,v in dict(DESC_BASE=meta['descriptor_base'],OUTPUT_BASE=output,BUILD_ID=build_id).items())
        (out/'jtag_layout.h').write_text(header,newline='\n')
        elf=build/'firmware.elf';binary=build/'firmware.bin'
        subprocess.run([gcc,'-march=rv32imc_zicsr','-mabi=ilp32','-Os','-g','-ffreestanding','-fno-builtin',
          '-fno-pic','-msmall-data-limit=0','-nostdlib','-Wl,--build-id=none','-Wl,--no-relax','-Wl,--gc-sections',
          '-T',str(ROOT/'sw/linker_banked.ld'),'-I',str(out),str(ROOT/'sw/startup.S'),str(ROOT/'sw/main_jtag.c'),'-o',str(elf)],check=True)
        subprocess.run([objcopy,'-O','binary',str(elf),str(binary)],check=True)
        cpu=binary.read_bytes();assert len(cpu)<=2048
        cpu+=bytes(2048-len(cpu))
        for name,data in (('cpu.hex',cpu),('model.hex',memory[begin:end])):
            (out/name).write_text(''.join('%08x\n'%v for v in struct.unpack('<%dI'%(len(data)//4),data)),newline='\n')
        manifest=dict(protocol_version=1,layout=layout,lanes=a.lanes,build_id=build_id,
          cache_words=a.cache_words if layout=='shared' else 0,boot_control=0x10030,boot_id=0x10034,
          mailbox=0x80001fc0,input_address=0x70004000+meta['activation_a'],output_address=0x70004000+output,
          input_bytes=784,output_bytes=10,cpu_code_limit=2048,clock_hz=50000000,
          loads=[dict(file='cpu.hex',address=0x80000000,bytes=len(cpu)),dict(file='model.hex',address=0x70004000+begin,bytes=end-begin)],
          sha256={n:hashlib.sha256((out/n).read_bytes()).hexdigest()for n in ('cpu.hex','model.hex')})
        (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',newline='\n')
        print(layout,'CPU',binary.stat().st_size,'bytes; model load',end-begin,'bytes; ID',hex(build_id))
if __name__=='__main__':main()
