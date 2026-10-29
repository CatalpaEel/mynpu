"""Lower model geometry into CPU-SRAM tile metadata and generic PE/IO words.

There are no sample values, expected results, weights or hardware programs in
this schedule: only addresses, masks and native CPU software constants.
"""
def command(op,dst=0,a=0,b=0,rows=0):
 return (op<<26)|(dst<<24)|(a<<19)|(b<<14)|(rows<<10)
def bundled_mac(rows,next_rows,advance=True):
 return command(6,0,2,3,rows)|0x100|(int(advance)<<7)|(4<<4)|next_rows

def check_stream_descriptor(words,context):
 """Software ban for the ABI-4 compact stream; never silently truncate."""
 for word in (0,3,4,8,9,10):
  if not -32768<=words[word]<=32767:
   raise ValueError('Context %d word %d exceeds signed16 stream range'%(context,word))
 for word in (5,6,7):
  if not 1<=words[word]<=65535:
   raise ValueError('Context %d axis %d exceeds uint16 stream shape'%(context,word-5))

def write_schedule(path,layers,fold=None):
 patterns=[];plans=[];records=[];previous_config=None;setups=[]
 for l in layers:
  src,dst,wb,bb,mb,ih,iw,ic,oc,oh,ow,stride,fc,relu,iz,oz,qmax=l
  nr0=4;nc0=min(4,oc);shape=nr0|(nc0<<4);previous=shape;plan=[]
  folded=fold if len(plans)==0 else None
  bb_config=folded['top_normal']if folded else bb
  old_w=wb;old_b=bb_config
  if fc and iz:raise ValueError('Static native FC expects zero input zero-point; use --dynamic')
  if not fc and not 1<=ic<=8:raise ValueError('Static unrolled kernel supports 1..8 channels; use --dynamic')
  if not fc and iz and not folded and ic!=1:raise ValueError('Static centered kernel supports one channel; use --dynamic')
  kernel=1 if fc else 3;terms=ic*kernel*kernel;plane=oh*ow
  cfg=[
   [src,16,0x44,0 if fc else stride,0,kernel,kernel,ic,1,iw,1 if fc else ih*iw,2,0],
   [wb,1|32,0x44,0,1,kernel,kernel,ic,4,kernel*4,kernel*kernel*4,3,0],
   [bb_config,4|32,0x44,0,4,2,1,1,mb-bb_config,0,0,4,0],
   [dst,8|64,shape,1,plane,1,1,1,0,0,0,0,0]]
  for c,words in enumerate(cfg):check_stream_descriptor(words,c)
  for co in range(0,oc,4):
   nc=min(4,oc-co)
   for oy in range(oh):
    for ox in range(0,ow,4):
     nr=min(4,ow-ox);rows=(1<<nr)-1;tile_shape=4|(nc<<4)
     yy=oy*stride-(not fc);xx=ox*stride-(not fc)
     masks=[sum(1<<r for r in range(nr)if 0<=yy+ky<ih and 0<=xx+r*stride+kx<iw)for ky in range(3)for kx in range(3)]if not fc else[rows]*9
     if masks not in patterns:patterns.append(masks)
     pattern=patterns.index(masks)
     a=src+yy*iw+xx;b=dst+co*plane+oy*ow+ox
     w=wb+(co//4)*terms*4
     bias=(folded['top_normal']if oy==0 else folded['body_normal'])if folded else bb+co*4
     flags=(0x100 if oy==0 and ox==0 else 0)|(0x200 if(w,bias)!=(old_w,old_b)else 0)|(0x400 if tile_shape!=previous else 0)|(128 if folded and ox==0 else 0)
     previous=tile_shape;old_w=w;old_b=bias
     if not all(0<=v<16384 for v in (a,b,w,bias)):raise ValueError('Static address outside shared SRAM')
     plan.append([(53<<26)|((a&8191)<<13)|(b&8191),w|(bias<<16),tile_shape|flags|(rows<<12)|(pattern<<16)])
  # The first layer fully initializes descriptors on EVERY inference.
  # Later setup blocks are compiler-proven deltas from the previous layer end.
  changed=[]
  for c in range(4):
   for w in range(13):
    if previous_config is None or cfg[c][w]!=previous_config[c][w]:changed.append((0x400+c*256+w*4,cfg[c][w]))
  setups.append(changed)
  previous_config=[r[:]for r in cfg]
  previous_config[0][0]=a;previous_config[1][0]=w_base=wb+((oc-1)//4)*terms*4
  previous_config[2][0]=old_b;previous_config[3][0]=b
  previous_config[3][2]=previous
  plans.append(plan);records.append((len(plan),ic,0 if folded else iz,fc,oz,oz if relu else 0,qmax,cfg))
 h='''#pragma once
#include <stdint.h>
struct tor_static_tile {uint32_t addresses,parameters,metadata;};
struct tor_static_layer {const struct tor_static_tile*tiles;uint32_t count,channels,center,fc,oz,lower,upper;void(*setup)(void);};
'''
 h+=''.join('extern void tor_setup_%d(void);\n'%i for i in range(6))
 h+='extern void tor_pattern_code(void);\n'
 h+=''.join('extern void tor_ci_plain%d(void);\n'%i for i in range(8))
 h+='extern void tor_ci_center7(void);\n'
 for li,p in enumerate(plans):
  h+='static const struct tor_static_tile tor_tiles_%d[%d]={\n'%(li,len(p))
  h+=''.join('{'+','.join('0x%08xu'%v for v in row)+'},\n'for row in p)+'};\n'
 h+='static const struct tor_static_layer tor_static_layers[6]={\n'
 for li,(count,ic,iz,fc,oz,lower,upper,cfg)in enumerate(records):
  entry=str(ic)+'u'if fc else'(uint32_t)tor_ci_%s%d'%('center'if iz else'plain',8-ic)
  h+='{tor_tiles_%d,'%li+str(count)+'u,'+entry+','+','.join(str(v)+'u'for v in [iz,fc,oz,lower,upper])+',tor_setup_%d},\n'%li
 h+='};\n';path.write_text(h)
 assembly='.option norelax\n.text\n'
 for li,changes in enumerate(setups):
  assembly+='.global tor_setup_%d\n.type tor_setup_%d,@function\ntor_setup_%d:\n'%(li,li,li)
  # Pair A=context0, B=context3; both bank1; reset all four contexts.
  if li==0:assembly+=' li t2,0x3fc\n sw t2,0x24(s4)\n'
  groups={}
  for offset,value in changes:groups.setdefault(value,[]).append(offset)
  for value,offsets in groups.items():
   if value:assembly+=' li t2,%d\n'%value
   for offset in offsets:assembly+=' sw %s,%d(s4)\n'%('t2'if value else'zero',offset)
  assembly+=' ret\n.size tor_setup_%d,.-tor_setup_%d\n'%(li,li)
 (path.parent/'torus_setup.S').write_text(assembly)
 patterns_asm='.option norelax\n.text\n.balign 64\n.global tor_pattern_code\ntor_pattern_code:\n'
 regs=['s1','a0','a1','a2','a3','a4','a5','a6','a7']
 for pi,m in enumerate(patterns):
  patterns_asm+='.balign 64,0\n.Lpattern_%d:\n'%pi;seen={};worst_bytes=2
  for i,r in enumerate(regs):
   word=bundled_mac(m[i],m[(i+2)%9])
   if word in seen:patterns_asm+=' mv %s,%s\n'%(r,seen[word]);worst_bytes+=2
   else:
    nearby=next(((v,p)for v,p in seen.items()if-2048<=word-v<=2047),None)
    if nearby:patterns_asm+=' addi %s,%s,%d\n'%(r,nearby[1],word-nearby[0]);worst_bytes+=4
    else:patterns_asm+=' li %s,0x%08x\n'%(r,word);worst_bytes+=8
   seen[word]=r
  if worst_bytes>64:raise ValueError('Pattern code exceeds fixed CPU slot')
  patterns_asm+=' ret\n'
 (path.parent/'torus_patterns.S').write_text(patterns_asm)
 return dict(setup_writes=sum(map(len,setups)),tiles=sum(map(len,plans)),patterns=len(patterns),plan_bytes=sum(map(len,plans))*12,pattern_code_bytes=len(patterns)*64)
