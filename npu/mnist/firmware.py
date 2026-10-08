from pathlib import Path
import json,struct
ROOT=Path(__file__).resolve().parent;OUT=ROOT/'artifacts';meta=json.loads((OUT/'model.json').read_text())
# Reuse the existing small RV32I assembler helpers, without executing its test program.
exec((ROOT.parent/'sw/gen_boot.py').read_text().split("label('_start')")[0])
def lbu(rd,base,off):emit(((off&4095)<<20)|(base<<15)|(4<<12)|(rd<<7)|3,'lbu')
def shift(rd,rs,imm,fun):emit((imm<<20)|(rs<<15)|(fun<<12)|(rd<<7)|0x13,'shift')
def alu(rd,a,b,fun):emit((b<<20)|(a<<15)|(fun<<12)|(rd<<7)|0x33,'alu')
def bge(a,b,target):code.append(('bge',a,b,target));listing.append('    bge')
label('_start');li(5,1<<16);emit((0x304<<20)|(5<<15)|(1<<12)|0x73,'csrw mie,x5');emit((0x300<<20)|(8<<15)|(7<<12)|0x73,'csrci mstatus,8');li(6,0x40000600);li(7,0x80000200);li(12,0x80001f00);li(13,0)
label('layer')
# Fourteen straight load/store pairs fit before the SRAM descriptor table.
for field in range(14):lw(5,7,field*4);sw(5,6,8+field*4)
li(5,1);sw(5,6,0)
li(9,1000000);label('poll');emit(0x10500073,'wfi');lw(8,6,4);andi(10,8,4);branch(10,0,'fail');andi(10,8,2);branch(10,0,'done');addi(9,9,-1);branch(9,0,'poll');jump('fail')
label('done');addi(13,13,1);sw(13,12,4)
lw(5,12,12);branch(5,0,'ack');jump('acked');label('ack');lw(8,12,8);branch(8,13,'ack');label('acked');addi(7,7,56);li(5,6);branch(13,5,'layer')
# FC output is packed quantized logits in buffer A. Compare unsigned values.
li(7,0x80001400);lw(11,7,0);andi(8,11,255);li(9,0);li(10,1);li(16,10)
label('argmax');shift(11,11,8,5);andi(17,10,3);branch(17,0,'loaded');addi(7,7,4);lw(11,7,0)
label('loaded');andi(18,11,255);bge(8,18,'skip');addi(8,18,0);addi(9,10,0)
label('skip');addi(10,10,1);branch(10,16,'argmax');sw(9,12,0)
li(6,0x40000000);li(5,0x600d0001);sw(5,6,4);jump('halt')
label('fail');li(6,0x40000000);li(5,0xbad00001);sw(5,6,4)
label('halt');jump('halt')
for i,w in enumerate(code):
 if isinstance(w,int):continue
 pc=0x80+4*i
 if w[0] in ('bne','bge'):
  _,a,b,t=w;off=labels[t]-pc;f=1 if w[0]=='bne' else 5
  code[i]=((off>>12&1)<<31)|((off>>5&63)<<25)|(b<<20)|(a<<15)|(f<<12)|((off>>1&15)<<8)|((off>>11&1)<<7)|0x63
 else:
  off=labels[w[1]]-pc;code[i]=((off>>20&1)<<31)|((off>>1&1023)<<21)|((off>>11&1)<<20)|((off>>12&255)<<12)|0x6f
assert 0x80+len(code)*4<=0x200
image=bytearray(1024)
for i,w in enumerate(code):struct.pack_into('<I',image,0x80+4*i,w)
h=28;cin=1
for i,L in enumerate(meta['layers']):
 out=[14,14,7,3,3,1][i];cout=L['shape'][0];src=0x80001400 if i%2==0 else 0x80001800;dst=0x80001800 if i%2==0 else 0x80001400
 fields=[src,L['weights'],L['quant'],dst,144 if i==5 else h,1 if i==5 else h,1 if i==5 else cin,cout,L['stride'],out,out,L['in_zero'],L['out_zero'],int(i==5)]
 for j,w in enumerate(fields):struct.pack_into('<I',image,0x200+i*56+j*4,w)
 L.update(src=src,dst=dst,output_bytes=out*out*cout)
 h=out;cin=cout
(OUT/'boot.hex').write_text(''.join(f'{v:02x}\n' for v in image));(OUT/'boot.S').write_text('\n'.join(listing));(OUT/'model.json').write_text(json.dumps(meta,indent=2))
(OUT/'test_meta.svh').write_text('localparam int PARAM_BYTES='+str(meta['parameter_bytes'])+';\n'+ 'int layer_len[6]=\'{'+','.join(str(L['output_bytes']) for L in meta['layers'])+'};\n'+ 'int prediction[10]=\'{'+','.join(str(S['prediction']) for S in meta['samples'])+'};\n')
print('Firmware instructions',len(code))

(OUT/'boot.bin').write_bytes(image)
params=bytes(int(line,16) for line in (OUT/'params.hex').read_text().splitlines())
(OUT/'params.bin').write_bytes(params)
for digit in range(10):
 full=bytearray(8192);full[:1024]=image;full[0x400:0x400+len(params)]=params
 inputs=bytes(int(line,16) for line in (OUT/f'input{digit}.hex').read_text().splitlines())
 full[0x1400:0x1400+784]=inputs;struct.pack_into('<I',full,0x1f00,0xffffffff)
 (OUT/f'sram{digit}.bin').write_bytes(full)
 (OUT/f'sram{digit}.hex').write_text(''.join(f'{v:02x}\n' for v in full))

macs=[];terms=[]
for i,L in enumerate(meta['layers']):
 if i==5:macs.append(1440);terms.append(1440);continue
 h=[28,14,14,7,3][i];out=[14,14,7,3,3][i];c=L['shape'][1];co=L['shape'][0]
 valid=sum(0<=p*L['stride']+k-1<h for p in range(out) for k in range(3))
 macs.append(valid*valid*c*co);terms.append(out*out*c*co*9)
with (OUT/'test_meta.svh').open('a') as f:
 f.write("int expected_macs[6]='{"+','.join(map(str,macs))+"};\n")
 f.write("int expected_terms[6]='{"+','.join(map(str,macs))+"};\n")
