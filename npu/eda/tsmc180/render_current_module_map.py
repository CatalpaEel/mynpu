"""Plot real instance rectangles exported from the final Innovus database."""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import re
from PIL import Image, ImageDraw, ImageFont

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--export',type=Path,required=True)
p.add_argument('--run',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args(); a.out.parent.mkdir(parents=True,exist_ok=True)
G={
 'CPU':('#60a5fa','CPU'), 'Debug':('#94a3b8','JTAG / DM / bootstrap'),
 'Matrix':('#f87171','Matrix compute'), 'Matrix_Stream':('#fb923c','Matrix Stream'),
 'CNN':('#a78bfa','CNN compute'), 'CNN_Stream':('#e879f9','CNN Stream / windows'),
 'Vector':('#4ade80','Vector ALU'), 'Vector_Stream':('#2dd4bf','Vector Stream / registers'),
 'Quant':('#facc15','Shared quantizer QT01'), 'RF':('#fef08a','Shared RF (256 B, 1R1W)'),
 'XBAR':('#38bdf8','XBAR / stream FIFOs'), 'MMIO':('#818cf8','MMIO / queues / events'),
 'SRAM':('#c4d6ed','SRAM macros (2 x 8 KiB)'), 'IO':('#64748b','IO / bond / corner'),
 'Support':('#cbd5e1','Other / physical support'), 'Filler':('#263242','Core filler'),
}
def classify(n,c):
 if c.startswith('FILL'):return 'Filler'
 if 'RA1SHD' in c:return 'SRAM'
 if c.startswith(('P','PAD')):return 'IO'
 for prefix,g in [
  ('i_core_i_xbar/i_regfile','RF'), ('i_core_i_matrix_stream/','Matrix_Stream'),
  ('i_core_i_vector_stream/','Vector_Stream'), ('i_core_i_vector_issue/','Vector_Stream'),
  ('i_core_i_stream/','CNN_Stream'), ('i_core_i_matmul/','Matrix'),
  ('i_core_i_cnn/','CNN'),('i_core_i_vector/','Vector'),('i_core_i_cpu/','CPU'),
  ('i_core_i_quant/','Quant'),('i_core_i_debug/','Debug'),('i_core_i_boot/','Debug'),
  ('i_core_i_xbar/','XBAR'),('i_core_i_mmio/','MMIO')]:
  if n.startswith('i_soc/'+prefix):return g
 return 'Support'
rows=[]; counts=Counter(); areas=Counter();seen=set()
for r in csv.DictReader((a.export/'instances.tsv').open(),delimiter='\t'):
 n=r['name'].strip('{}');assert n not in seen;seen.add(n)
 box=tuple(float(r[k]) for k in ['x0','y0','x1','y1'])
 assert box[2]>=box[0] and box[3]>=box[1]
 g=classify(n,r['cell']);rows.append((g,box,n));counts[g]+=1;areas[g]+=(box[2]-box[0])*(box[3]-box[1])
assert len(rows)>100000 and counts['SRAM']==2 and counts['RF']>2000
geometry=(a.export/'geometry.txt').read_text()
boxes={k:tuple(map(float,re.search(k+r'=\{([^}]+)\}',geometry)[1].split())) for k in ['die','core']}
font_path='/usr/share/fonts/dejavu/DejaVuSans.ttf'
def font(n):return ImageFont.truetype(font_path,n)
for view,box in boxes.items():
 W,H=2680,2120;im=Image.new('RGB',(W,H),'#101722');d=ImageDraw.Draw(im)
 d.text((55,28),'mynpu | RF 1R1W | final r3',font=font(39),fill='white')
 d.text((55,85),'Actual Innovus instance locations, colored by preserved hierarchy',font=font(24),fill='#bdc9dc')
 d.text((55,122),f'{view.upper()} VIEW  |  die 1950 x 1950 um  |  50 MHz  |  {len(rows):,} instances exported',font=font(22),fill='#bdc9dc')
 x0,y0,x1,y1=box;scale=1840/max(x1-x0,y1-y0);ox,oy=55,190
 d.rectangle((ox,oy,ox+(x1-x0)*scale,oy+(y1-y0)*scale),fill='#080c14',outline='#8798b0',width=2)
 # Paint filler and IO first; logical cells retain visibility on top.
 ordered=sorted(rows,key=lambda r:0 if r[0] in ['Filler','IO'] else 1 if r[0]=='SRAM' else 2)
 for g,(xx0,yy0,xx1,yy1),n in ordered:
  if xx1<x0 or xx0>x1 or yy1<y0 or yy0>y1:continue
  b=(ox+(max(xx0,x0)-x0)*scale,oy+(y1-min(yy1,y1))*scale,
     ox+(min(xx1,x1)-x0)*scale,oy+(y1-max(yy0,y0))*scale)
  d.rectangle(b,fill=G[g][0])
  if g=='SRAM':
   d.rectangle(b,outline='white',width=2)
   d.text((b[0]+16,b[1]+16),n.split('/')[1],font=font(24),fill='#18263b')
 lx=1960;yy=198
 for g,(color,label) in G.items():
  d.rectangle((lx,yy+3,lx+24,yy+27),fill=color)
  d.text((lx+39,yy),label,font=font(23),fill='white')
  d.text((lx+39,yy+34),f'{counts[g]:,} cells  |  {areas[g]/1e6:.6f} mm2',font=font(19),fill='#bdc9dc')
  yy+=91
 d.text((1960,1720),'Area = sum of cell bounding boxes.',font=font(20),fill='#bdc9dc')
 d.text((1960,1758),'IO / bond rectangles may overlap.',font=font(20),fill='#bdc9dc')
 d.text((1960,1796),'No routing overlay. Not power density.',font=font(20),fill='#bdc9dc')
 d.text((55,2050),'Source: 14_exported.enc.dat | RF/Stream classified from flattened instance-name prefixes',font=font(22),fill='#bdc9dc')
 im.save(a.out.with_name(a.out.name+'-'+view+'.png'))

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
outputs=[a.out.with_name(a.out.name+'-'+v+'.png') for v in boxes]
record={'scope':'Actual final r3 instance bounding boxes, not an illustrative floorplan. Routing omitted; bbox areas can overlap at IO/bond.',
 'run':str(a.run.resolve()),'checkpoint':'14_exported.enc.dat','die_box_um':boxes['die'],'core_box_um':boxes['core'],
 'instance_count':len(rows),'groups':{g:{'color':G[g][0],'label':G[g][1],'cells':counts[g],'bbox_area_mm2':areas[g]/1e6} for g in G},
 'sha256':{str(p.resolve()):sha(p) for p in [a.export/'instances.tsv',a.export/'export.tcl',a.export/'export.log',a.run/'manifest.json',a.run/'mynpu/pnr/checkpoints/14_exported.enc',Path(__file__),*outputs]}}
a.out.with_suffix('.source.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'instances':len(rows),'counts':counts,'outputs':list(map(str,outputs))},indent=2))
