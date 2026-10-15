"""Relocate the existing quantized model into shared, word-striped 2x8KB SRAM.

No new quantization: assert all six layers equal the previous integer golden.
CPU code is in physical bank0[0:2KB], stack/mailbox in its final 1088 bytes.
Model segments are loaded once, and never duplicated in CPU .rodata.
"""
import json, struct, argparse, subprocess
from pathlib import Path
from build_firmware import integer_golden,c_words
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--gcc');p.add_argument('--objcopy');a=p.parse_args()
    src=ROOT/'cnn_npu_int8/generated/8k-p4';out=ROOT/'generated/dual-bank';out.mkdir(parents=True,exist_ok=True)
    old=json.loads((src/'golden.json').read_text());raw=bytes(int(s,16) for s in (src/'cnn_npu_mem.hex').read_text().split())
    db,aa,ab,end=0x2400,0x2800,0x3000,0x3400
    mem=bytearray(16384);cursor=0x1000
    meta=dict(old,sram_bytes=16384,descriptor_base=db,activation_a=aa,activation_b=ab,
              parameter_base=0x1000,model_load_end=end)
    meta['layers']=[]
    for i,l in enumerate(old['layers']):
        d=list(struct.unpack_from('<9I',raw,old['descriptor_base']+i*36))
        original=list(d);ic=(d[6]>>16)&255;oc=d[6]>>24;terms=ic*(1 if d[7]>>24&1 else 9)
        n=((oc+3)//4)*4*terms;weights=raw[d[2]:d[2]+n]
        d[0]=aa if d[0]==old['activation_a'] else ab
        d[1]=aa if d[1]==old['activation_a'] else ab
        d[2]=cursor
        mem[cursor:cursor+len(weights)]=weights;cursor+=len(weights)
        for field,size in ((3,oc*4),(4,oc*4),(5,oc)):
            cursor=(cursor+3)&~3;d[field]=cursor;mem[cursor:cursor+size]=raw[original[field]:original[field]+size];cursor+=size
        cursor=(cursor+3)&~3
        struct.pack_into('<9I',mem,db+i*36,*d)
        lm=dict(l,in_base=d[0],out_base=d[1]);lm.update(zip(('weight','bias','multiplier','shift'),d[2:6]));meta['layers'].append(lm)
    param=cursor-0x1000;assert cursor<=db
    meta['parameter_bytes']=param
    mem[aa:aa+784]=bytes(old['input_codes'])
    layers=integer_golden(mem,meta);assert layers==integer_golden(raw,old)
    (out/'golden.json').write_text(json.dumps(meta,indent=2)+'\n')
    (out/'model_word.hex').write_text(''.join('%08x\n'%w for w in struct.unpack('<4096I',mem)))
    (out/'integer_layers.hex').write_text(''.join('%02x\n'%v for layer in layers for v in layer))
    pt=old['pytorch_layer_codes']+[old['expected_output_codes']]
    (out/'pytorch_layers.hex').write_text(''.join('%02x\n'%v for layer in pt for v in layer))
    header='#pragma once\n#define DESC_BASE %du\n#define INPUT_BASE %du\n#define OUTPUT_BASE %du\n'%(db,aa,aa)
    (out/'layout.svh').write_text('`ifndef MYNPU_DB_LAYOUT\n`define MYNPU_DB_LAYOUT\n'+
       ''.join('`define %s 32\'h%08x\n'%(name,value)for name,value in(
           ('DB_DESC_BASE',db),('DB_INPUT_BASE',aa),('DB_MODEL_END',end)))+'`endif\n')
    header+=c_words('model_input',old['input_codes'])
    header+='static const unsigned char integer_output[10]={'+','.join(map(str,layers[-1]))+'};\n'
    (out/'model_data.h').write_text(header)
    if not a.gcc:return
    objcopy=a.objcopy or a.gcc.replace('gcc','objcopy')
    build=ROOT/'build/dual-bank';build.mkdir(parents=True,exist_ok=True)
    for stream in (False,True):
        name='cpu_stream' if stream else 'cpu'
        elf=build/(name+'.elf');binary=build/(name+'.bin')
        cmd=[a.gcc,'-march=rv32imc_zicsr','-mabi=ilp32','-Os','-g','-ffreestanding','-fno-builtin','-fno-pic',
             '-msmall-data-limit=0','-nostdlib','-Wl,--build-id=none','-Wl,--no-relax','-Wl,--gc-sections',
             '-T',str(ROOT/'sw/linker_banked.ld'),'-I',str(out),str(ROOT/'sw/startup.S'),str(ROOT/'sw/main_banked.c'),'-o',str(elf)]
        if stream:cmd.insert(1,'-DHOST_STREAM=1')
        subprocess.run(cmd,check=True);subprocess.run([objcopy,'-O','binary',str(elf),str(binary)],check=True)
        data=binary.read_bytes();assert len(data)<=2048,('CPU code exceeds bank0 reservation',len(data))
        cpu=data+bytes(8192-len(data));(out/(name+'.hex')).write_text(''.join('%08x\n'%v for v in struct.unpack('<2048I',cpu)))
        # Complete physical images for FPGA bitstream initialization. ASIC TB
        # explicitly loads CPU first, then model segments via real JTAG/SBA.
        banks=[bytearray(cpu),bytearray(8192)]
        for off in range(0x1000,end,4):
            banks[(off>>2)&1][(off>>3)*4:(off>>3)*4+4]=mem[off:off+4]
        for b in range(2):(out/(name+f'_bank{b}.hex')).write_text(''.join('%08x\n'%v for v in struct.unpack('<2048I',banks[b])))
        print(name,len(data),'bytes; parameters',param,'bytes; two 8KB macros')
if __name__=='__main__':main()
