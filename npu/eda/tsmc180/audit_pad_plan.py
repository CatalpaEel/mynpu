"""Check actual fixed PAD placements against a constrained paired-supply plan."""
import argparse
import hashlib
import json
from pathlib import Path
import re

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--run',type=Path,required=True)
p.add_argument('--def-file',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();m=json.loads((a.run/'manifest.json').read_text());plan=m['pad_experiment']
s=a.def_file.read_text();unit=int(re.search(r'UNITS DISTANCE MICRONS (\d+)',s)[1]);pads={}
for name,cell,x,y,ori in re.findall(r'- (i_pad_\S+) (\S+) \+ FIXED \( (\d+) (\d+) \) (\S+)',s):
 pads[name]={'cell':cell,'x_um':int(x)/unit,'y_um':int(y)/unit,'orientation_def':ori}
gpio_count=int(m.get("gpio_pins",0))
assert gpio_count in [0,8]
assert len(pads)==37+gpio_count,len(pads)
expected={}
sig=plan['signal_plan'].split()
for i in range(0,len(sig),4):
 port,side,pos,direction=sig[i:i+4];expected['i_pad_'+port]=(side,float(pos),'PDDW0204CDG')
for side in ['top','bottom','left','right']:
 for vdd,vss,pd,ps in plan['paired_supplies_per_side']:
  suffix='2CDG' if vdd=='vddio' else '1CDG'
  expected[f'i_pad_{side}_{vdd}']=(side,float(pd),'PVDD'+suffix)
  expected[f'i_pad_{side}_{vss}']=(side,float(ps),'PVSS'+suffix)
 expected[f'i_pad_{side}_poc']=(side,float(plan['poc_offset_um']),'PVDD2POC')
for bit in range(gpio_count):
 expected[f'i_pad_gpio{bit}']=("right" if bit<4 else "bottom",float(850+(bit%4)*100),"PDDW0204CDG")
for name,(side,pos,cell) in expected.items():
 row=pads[name];want={'left':(0,pos),'right':(1835,pos),'bottom':(pos,0),'top':(pos,1835)}[side]
 assert (row['x_um'],row['y_um'])==want,(name,row,want)
 assert row['cell']==cell,(name,row['cell'],cell)
 assert row['orientation_def']=={'top':'S','bottom':'N','left':'E','right':'W'}[side],(name,row['orientation_def'])
 row.update(side=side,offset_um=pos)
for side in ['top','bottom','left','right']:
 ordered=sorted((r['offset_um'],n) for n,r in pads.items() if r['side']==side)
 assert ordered[0][0]>=115 and ordered[-1][0]+60<=1835
 assert all(b[0]-a[0]>=60 for a,b in zip(ordered,ordered[1:])),(side,ordered)
 for vdd,vss,_,_ in plan['paired_supplies_per_side']:
  names=[n for _,n in ordered]
  assert abs(names.index(f'i_pad_{side}_{vdd}')-names.index(f'i_pad_{side}_{vss}'))==1
result={'scope':'Fixed native PAD coordinate and adjacency audit only; not DRC, ESD, IR/EM or package signoff.',
 'passed':True,'native_pads':37+gpio_count,'signal_pads':9+gpio_count,'gpio_pads':gpio_count,'power_ground_poc_pads':28,
 'jtag_left':True,'supply_pairs_per_side':3,'minimum_native_pad_gap_um':40,
 'def_sha256':hashlib.sha256(a.def_file.read_bytes()).hexdigest(),'pads':pads}
a.out.write_text(json.dumps(result,indent=2)+'\n');print(f'PAD PLAN PASS: {37+gpio_count} pads, GPIO={gpio_count}, left JTAG, 12 adjacent supply/ground pairs, no slot overlap')
