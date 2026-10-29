"""Build native CPU software, one parameter image and independent integer goldens."""
import argparse,hashlib,json,shutil,struct,subprocess,sys
from pathlib import Path
from build_firmware import integer_golden
from torus_schedule import write_schedule
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--out',type=Path,default=ROOT/'build/torus/assets')
 p.add_argument('--corpus',type=Path,default=ROOT/'tests/torus/mnist_vectors.json');p.add_argument('--vectors',type=int,default=8)
 p.add_argument('--cache-words',type=int,choices=[16,32,64],default=32)
 p.add_argument('--no-bias-fold',action='store_true')
 p.add_argument('--dynamic',action='store_true',help='Use the earlier runtime-geometry CPU scheduler')
 p.add_argument('--serial',action='store_true',help='Disable software prefetch overlap for A/B measurement')
 p.add_argument('--full-config',action='store_true',help='Rewrite descriptors every tile for A/B measurement')
 p.add_argument('--compiler-python',default=str(ROOT.parent/'mynpu-review-78f7844/.venv-general/bin/python'))
 a=p.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 folder=ROOT/'cnn_npu_int8/generated/8k-p4';meta=json.loads((folder/'golden.json').read_text())
 original=bytes(int(v,16)for v in(folder/'cnn_npu_mem.hex').read_text().split())
 model=bytearray(8192);model[:4288]=original[:4288];layers=[];sizes=[];offsets=[];semantic=[]
 for li in range(6):
  d=struct.unpack_from('<9I',original,meta['descriptor_base']+li*36)
  src,dst,wb,bb,mb,sb,shape,outword,q=d
  ih,iw,ic,oc=[shape>>(8*k)&255 for k in range(4)]
  oh,ow,stride,flags=[outword>>(8*k)&255 for k in range(4)]
  iz,oz,qmax=[q>>(8*k)&255 for k in range(3)];fc=int(bool(flags&1));terms=ic*(1 if fc else 9)
  if not flags&4:raise ValueError('Expected one PACK4 weight image')
  semantic.append(dict(shape=d[6:9],weights=original[wb:wb+((oc+3)//4)*terms*4].hex(),bias=original[bb:bb+oc*4].hex(),mult=original[mb:mb+oc*4].hex(),shift=original[sb:sb+oc].hex()))
  for co in range(oc):
   m=struct.unpack_from('<i',original,mb+co*4)[0]
   if original[sb+co]!=31 or not 0<=m<1<<30:raise ValueError('This compiler needs shift=31 and 2M representable in int32')
   struct.pack_into('<i',model,mb+co*4,2*m)
  offsets.append(sum(sizes));sizes.append(oc*oh*ow)
  layers.append([0x3100 if li%2==0 else 0x3420,0x3420 if li%2==0 else 0x3100,wb+0x2000,bb+0x2000,mb+0x2000,ih,iw,ic,oc,oh,ow,stride,fc,int(bool(flags&2)),iz,oz,qmax])
 signature=hashlib.sha256(json.dumps(semantic,sort_keys=True).encode()).hexdigest()
 vectors=[dict(input=meta['input_codes'],pytorch=meta['expected_output_codes'])]
 if a.corpus:
  corpus=json.loads(a.corpus.read_text())
  if corpus.get('model_semantic_sha256',signature)!=signature:raise ValueError('Corpus parameters do not match')
  vectors=corpus['vectors']
 if not 1<=a.vectors<=len(vectors):p.error('Requested vectors exceed corpus')
 vectors=vectors[:a.vectors];inputs=[];gold=[];final=[];max_error=0;pychecked=0
 for v in vectors:
  image=bytearray(original);image[meta['activation_a']:meta['activation_a']+784]=bytes(v['input'])
  y=integer_golden(image,meta)
  if 'integer'in v and y[-1]!=v['integer']:raise ValueError('Recorded integer output does not match model')
  inputs+=v['input'];gold+=sum(y,[]);final.append(y[-1])
  if 'pytorch'in v:
   pychecked+=1;max_error=max(max_error,max(abs(x-z)for x,z in zip(y[-1],v['pytorch'])))
 if max_error>1:raise ValueError('Recorded PyTorch output differs by more than one code')
 fields='src,dst,wb,bb,mb,ih,iw,ic,oc,oh,ow,stride,fc,relu,iz,oz,qmax'
 header='#pragma once\n#include <stdint.h>\nstruct tor_layer{uint32_t '+fields+';};\n'
 header+='static const struct tor_layer tor_layers[6]={\n'+''.join('{'+','.join(map(str,l))+'},\n'for l in layers)+'};\n'
 for name,values in [('sizes',sizes),('offsets',offsets)]:header+='static const unsigned tor_'+name+'[6]={'+','.join(map(str,values))+'};\n'
 header+='static const unsigned tor_outputs[6]={'+','.join(str(l[1])for l in layers)+'};\n'
 fold=None
 if not(a.no_bias_fold or a.dynamic or a.serial or a.full_config):
  l=layers[0];src,dst,wb,bb,mb,ih,iw,ic,oc,oh,ow,stride,fc,relu,iz,oz,qmax=l
  if(ic,oc,stride,fc,ih,iw,oh,ow,iz)==(1,2,2,0,28,28,14,14,17):
   base=0x3740
   for top in [True,False]:
    for left in [False,True]:
     for co in range(oc):
      bias=struct.unpack_from('<i',original,bb-0x2000+co*4)[0];weight_sum=0
      for ky in range(3):
       for kx in range(3):
        if(top and ky==0)or(left and kx==0):continue
        raw=original[wb-0x2000+(ky*3+kx)*4+co];weight_sum+=raw if raw<128 else raw-256
      value=(bias-iz*weight_sum)&0xffffffff
      offset=base-0x2000+(0 if top else 16)+(8 if left else 0)+co*4
      struct.pack_into('<I',model,offset,value)
   model[bb-0x2000:bb-0x2000+oc*4]=bytes(oc*4)
   fold=dict(top_normal=base,body_normal=base+16,bytes=32,input_zero_point=iz)
 (out/'torus_model.h').write_text(header)
 dynamic=a.dynamic or a.serial or a.full_config
 schedule=None if dynamic else write_schedule(out/'torus_static.h',layers,fold)
 for name,values in [('inputs',inputs),('golden',gold)]: (out/(name+'.hex')).write_text(''.join('%02x\n'%v for v in values))
 (out/'model.hex').write_text(''.join('%08x\n'%v for v in struct.unpack('<2048I',model)))
 gcc=shutil.which('riscv64-unknown-elf-gcc')
 if gcc:cc=[gcc,'-march=rv32imc_zicsr'];objcopy=[gcc.replace('gcc','objcopy')]
 else:cc=[a.compiler_python,'-m','ziglang','cc','-target','riscv32-freestanding','-mcpu=generic_rv32+m+c+zicsr'];objcopy=[a.compiler_python,'-m','ziglang','objcopy']
 flags=['-DTORUS_HAS_CENTER=%d'%(fold is None),'-DTORUS_OVERLAP=%d'%(not a.serial),'-DTORUS_COMPACT_CONFIG=%d'%(not a.full_config),'-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-fno-pic','-msmall-data-limit=0','-nostdlib','-Wl,--build-id=none','-Wl,--gc-sections','-T','sw/linker.ld','-I',str(out)]
 startup=out/'startup.S';startup.write_text('.option norelax\n'+(ROOT/'sw/startup.S').read_text())
 with(out/'compile.log').open('w')as log:
  subprocess.run(cc+flags+[str(startup)]+(['sw/torus/main.c','sw/torus/issue.S']if dynamic else['sw/torus/main_static.c','sw/torus/issue_native.S',str(out/'torus_setup.S'),str(out/'torus_patterns.S')])+['-o',str(out/'cpu.elf')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
  subprocess.run(objcopy+['-O','binary',str(out/'cpu.elf'),str(out/'cpu.bin')],stdout=log,stderr=subprocess.STDOUT,check=True)
 data=(out/'cpu.bin').read_bytes();size=len(data)
 if size>0x1bc0:raise ValueError('Firmware overlaps stack')
 data+=bytes(8192-size);(out/'cpu.hex').write_text(''.join('%08x\n'%v for v in struct.unpack('<2048I',data)))
 record=dict(bias_fold=fold,model_load_words=(0x1760//4 if fold else 1072),cache_words=a.cache_words,native_driver=not dynamic,static_schedule=schedule,bundled=not dynamic,overlap=not a.serial,compact_config=not a.full_config,architecture='16PE torus, local 4x32 RF, independent neighbor read register, native CPU control',vectors=len(vectors),cpu_bytes=size,parameter_bytes=4288,model_semantic_sha256=signature,pytorch_vectors=pychecked,pytorch_max_code_error=max_error,sizes=sizes,offsets=offsets,layers=layers,final=final,quantization='PE MULHR(acc,2M), ADD zp, MAX lower, MIN upper; no external arithmetic')
 (out/'manifest.json').write_text(json.dumps(record,indent=2)+'\n');print(out,'CPU',size,'bytes, vectors',len(vectors),'PyTorch records',pychecked)
if __name__=='__main__':main()
