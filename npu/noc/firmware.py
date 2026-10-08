"""Real RV32I CPU initiates a network DMA and sleeps on IRQ21."""
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parent
exec((ROOT.parent/'sw/gen_boot.py').read_text().split("label('_start')")[0])
label('_start');li(5,1<<21);emit((0x304<<20)|(5<<15)|(1<<12)|0x73,'csrw mie,x5');emit((0x300<<20)|(8<<15)|(7<<12)|0x73,'csrci mstatus,8')
li(6,0x40000700)
for off,value in ((8,0x111),(12,0x80001a00),(16,16),(20,0x80001400),(24,10000),(0,1)):write_mmio(off,value)
label('wait');emit(0x10500073,'wfi');lw(8,6,4);andi(10,8,4);branch(10,0,'fail');andi(10,8,2);branch(10,0,'done');jump('wait')
label('done');lw(8,6,28);li(11,16);branch(8,11,'fail');write_mmio(0,2)
li(6,0x40000000);write_mmio(4,0x600d0001);jump('halt')
label('fail');li(6,0x40000000);write_mmio(4,0xbad00001)
label('halt');jump('halt')
for i,w in enumerate(code):
 if isinstance(w,int):continue
 pc=0x80+4*i
 if w[0]=='bne':
  _,a,b,t=w;off=labels[t]-pc
  code[i]=((off>>12&1)<<31)|((off>>5&63)<<25)|(b<<20)|(a<<15)|(1<<12)|((off>>1&15)<<8)|((off>>11&1)<<7)|0x63
 else:
  off=labels[w[1]]-pc;code[i]=((off>>20&1)<<31)|((off>>1&1023)<<21)|((off>>11&1)<<20)|((off>>12&255)<<12)|0x6f
assert 0x80+len(code)*4<=1024
image=bytearray(1024)
for i,w in enumerate(code):struct.pack_into('<I',image,0x80+4*i,w)
out=ROOT.parent/'mnist/artifacts';(out/'noc_boot.hex').write_text(''.join(f'{v:02x}\n' for v in image));(out/'noc_boot.bin').write_bytes(image)
(ROOT/'boot.S').write_text('\n'.join(listing));print('NoC CPU firmware instructions',len(code))
