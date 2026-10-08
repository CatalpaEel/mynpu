"""Two SRAM input slots, shared scratch, concurrent host DMA and CNN inference."""
from pathlib import Path
import json,struct
ROOT=Path(__file__).resolve().parent;OUT=ROOT/'artifacts';meta=json.loads((OUT/'model.json').read_text())
exec((ROOT/'firmware.py').read_text().split("label('_start');li")[0])
def xori(rd,rs,imm):emit(((imm&4095)<<20)|(rs<<15)|(4<<12)|(rd<<7)|0x13,'xori')
A=0x80001360;B=0x80001670;C=0x80001980;PACKETS=0x80001c90;MAIL=0x80001fa0;DESC=0x800002b0
label('_start');li(5,1<<16);emit((0x304<<20)|(5<<15)|(1<<12)|0x73,'csrw mie');emit((0x300<<20)|(8<<15)|(7<<12)|0x73,'csrci mstatus,8')
li(6,0x40000600);li(12,MAIL);li(19,0);li(20,0);li(21,0);li(25,A);li(27,0);li(28,0);lw(22,12,24);branch(22,0,'frame');jump('fail')
label('frame');shift(23,21,2,1);alu(23,23,12,0);addi(24,19,1)
label('ready');lw(8,23,0);branch(8,24,'ready');alu(26,25,20,0);li(7,DESC);li(13,0)
label('layer');addi(14,7,0);addi(15,6,8);li(16,14)
label('config');lw(5,14,0);branch(5,25,'keep');alu(5,5,20,0)
label('keep');sw(5,15,0);addi(14,14,4);addi(15,15,4);addi(16,16,-1);branch(16,0,'config');li(5,1);sw(5,6,0)
label('wait');emit(0x10500073,'wfi');lw(8,6,4);andi(10,8,4);branch(10,0,'fail');andi(10,8,2);branch(10,0,'layer_done');jump('wait')
label('layer_done');lw(8,6,0x40);alu(27,27,8,0);lw(8,6,0x44);alu(28,28,8,0)
addi(13,13,1);addi(7,7,56);li(5,6);branch(13,5,'layer')
# Copy packed logits before granting ownership of the input slot back to host.
li(30,PACKETS);shift(17,21,4,1);alu(30,30,17,0)
for off in (0,4,8):
 lw(8,26,off)
 if off==8:shift(8,8,16,1);shift(8,8,16,5)
 sw(8,30,off)
addi(7,26,0);lw(8,7,0);andi(8,8,255);li(9,0);li(10,1)
label('argmax');shift(17,10,2,5);shift(17,17,2,1);alu(17,17,7,0);lw(11,17,0);andi(18,10,3);shift(18,18,3,1);alu(11,11,18,5);andi(11,11,255);bge(8,11,'skip');addi(8,11,0);addi(9,10,0)
label('skip');addi(10,10,1);li(11,10);branch(10,11,'argmax');sw(9,30,12);sw(9,23,16)
sw(27,12,32);sw(28,12,36);sw(24,23,8);addi(19,19,1);branch(19,22,'more');jump('success')
label('more');xori(21,21,1);li(20,0);branch(21,0,'slot1');jump('frame')
label('slot1');li(20,C-A);jump('frame')
label('success');li(6,0x40000000);li(5,0x600d0001);sw(5,6,4);jump('halt')
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
assert 0x80+len(code)*4<=0x2b0,len(code)
image=bytearray(1024)
for i,w in enumerate(code):struct.pack_into('<I',image,0x80+4*i,w)
h=28;cin=1
for i,L in enumerate(meta['layers']):
 out=[14,14,7,3,3,1][i];cout=L['shape'][0]
 fields=[A if i%2==0 else B,L['weights'],L['quant'],B if i%2==0 else A,144 if i==5 else h,1 if i==5 else h,1 if i==5 else cin,cout,L['stride'],out,out,L['in_zero'],L['out_zero'],int(i==5)]
 for j,w in enumerate(fields):struct.pack_into('<I',image,0x2b0+i*56+j*4,w)
 h=out;cin=cout
(OUT/'stream_boot.hex').write_text(''.join(f'{v:02x}\n' for v in image));(OUT/'stream_boot.bin').write_bytes(image);(OUT/'stream_boot.S').write_text('\n'.join(listing))
(OUT/'stream.json').write_text(json.dumps(dict(input_slots=[A,C],scratch=B,output_packets=PACKETS,mailbox=MAIL,descriptor=DESC,cache_data_bytes=128,instructions=len(code)),indent=2))
print('Stream firmware instructions',len(code))
