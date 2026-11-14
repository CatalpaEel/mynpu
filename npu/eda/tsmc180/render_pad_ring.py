"""Draw native PAD boxes from the audited DEF placements (not a new floorplan)."""
import argparse,json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--audit',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
p.add_argument('--title',default='mynpu | left-side JTAG + paired power PAD trial')
a=p.parse_args();data=json.loads(a.audit.read_text());assert data['passed']
im=Image.new('RGB',(2100,2200),'#101722');d=ImageDraw.Draw(im)
f='/usr/share/fonts/dejavu/DejaVuSans.ttf';font=lambda n:ImageFont.truetype(f,n)
d.text((70,35),a.title,font=font(36),fill='white')
d.text((70,92),'Actual fixed PAD coordinates | 1950 x 1950 um | not yet physical signoff',font=font(24),fill='#becbdf')
ox,oy,scale=160,230,.90
p0=lambda x,y:(ox+x*scale,oy+(1950-y)*scale)
x,y=p0(0,1950);xx,yy=p0(1950,0)
d.rectangle((x,y,xx,yy),outline='#e2e8f0',width=3)
for name,r in data['pads'].items():
 side=r['side'];pos=r['offset_um'];n=name.removeprefix('i_pad_')
 label=n.removeprefix(side+'_').upper()
 power='PVDD' in r['cell'];ground='PVSS' in r['cell'];jtag=n in ['tck_i','tms_i','td_i','td_o']
 color='#f87171' if power else '#60a5fa' if ground else '#4ade80' if jtag else '#c4b5fd'
 if label=='POC':color='#fbbf24'
 x0,y0=r['x_um'],r['y_um'];w,h=(115,60) if side in ['left','right'] else (60,115)
 b=(*p0(x0,y0+h),*p0(x0+w,y0));d.rectangle(b,fill=color,outline='#111827',width=2)
 if side in ['left','right']:
  cy=p0(x0,pos+30)[1];lx=ox+135 if side=='left' else ox+1950*scale-135
  text=f'{label}  ({pos:g})' if side=='left' else f'({pos:g})  {label}'
  d.text((lx,cy),text,font=font(23),fill=color,anchor='lm' if side=='left' else 'rm')
 else:
  # Vertical annotations keep adjacent native pad names readable.
  label_im=Image.new('RGBA',(450,45),(0,0,0,0));ld=ImageDraw.Draw(label_im)
  ld.text((0,4),f'{label} ({pos:g})',font=font(23),fill=color)
  label_im=label_im.rotate(90 if side=='bottom' else -90,expand=True)
  px=p0(pos+30,0)[0]-22
  py=oy+1950*scale-115-450 if side=='bottom' else oy+120
  im.paste(label_im,(int(px),int(py)),label_im)
d.text((1050,1005),'CORE',font=font(50),fill='#64748b',anchor='mm')
d.text((1050,1070),'12 adjacent VDD/VSS pairs across 4 sides',font=font(26),fill='#cbd5e1',anchor='mm')
d.text((1050,1120),'JTAG: TCK / TMS / TDI / TDO on LEFT',font=font(26),fill='#4ade80',anchor='mm')
d.text((1050,1170),f"POC retained separately; {data['signal_pads']} signal + 28 supply/POC PADs",font=font(23),fill='#cbd5e1',anchor='mm')
d.text((70,2045),'Red: VDD    Blue: VSS    Green: JTAG    Yellow: POC',font=font(25),fill='white')
d.text((70,2095),'Numbers: lower/left native PAD edge coordinate, um. Pair adjacency permits IO filler.',font=font(23),fill='#becbdf')
a.out.parent.mkdir(parents=True,exist_ok=True);im.save(a.out);print(a.out)
