#!/usr/bin/env python3
"""Generate transport-independent MMIO writes + ingress stream beats for boot.
An external bus/USB/SPI/AXI bridge executes the produced JSON protocol steps.
This script does not preinitialize hardware SRAM or add a ROM.
"""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('image',nargs='?',type=Path,default=Path(__file__).with_name('boot.hex'))
p.add_argument('--output',type=Path,default=Path(__file__).with_name('boot_transfer.json'))
p.add_argument('--entry',type=lambda s:int(s,0),default=0x80000080)
a=p.parse_args()
words=[int(w,16) for w in a.image.read_text().split()]
assert 1<=len(words)<=2048 and 0x80000000<=a.entry<0x80000000+len(words)*4 and a.entry%4==0
base=0x40000000
steps=[{'write32':hex(base+off),'value':hex(val)} for off,val in [
    (8,0),(4,0),(0x30c,0x80000000),(0x310,len(words)*4),(0x314,1),
    (0x31c,len(words)*4),(0x320,0),(0x334,0),(0x300,1)]]
steps += [{'rx_data':f'0x{w:08x}','keep':15,'last':i==len(words)-1} for i,w in enumerate(words)]
steps += [{'poll32':hex(base+0x304),'mask':7,'expected':2,'fail_mask':4},
          {'read32':hex(base+0x328),'expected':len(words)*4},
          {'write32':hex(base+12),'value':hex(a.entry)},
          {'write32':hex(base+8),'value':'0x1'}]
a.output.write_text(json.dumps({'word_byte_order':'little-endian','steps':steps},indent=2)+'\n')
print(f'Prepared external DMA boot: {len(words)*4} bytes, entry={a.entry:#x}, {a.output}')
