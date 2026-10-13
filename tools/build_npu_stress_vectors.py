"""Create independent randomized single-layer golden vectors for vector RTL.

Alternate legacy/packed4 weights, FC/conv, stride1/2, unaligned activations
and outputs, channel tails, saturation, accumulator wrap, and shifts 0/1/31/63.
Every SRAM byte outside the output must remain identical to its input image.
"""
import argparse
import json
import random
import struct
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def i32(x): return ((x+(1<<31))%(1<<32))-(1<<31)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--cases',type=int,default=200)
    ap.add_argument('--seed',type=int,default=14596)
    args=ap.parse_args()
    rng=random.Random(args.seed)
    folder=ROOT/'build/npu-vector-stress'
    folder.mkdir(parents=True,exist_ok=True)
    with (folder/'input.hex').open('w') as source, (folder/'expected.hex').open('w') as expected:
        records=[]
        for case in range(args.cases):
            fc=(case%3==0); packed=(case%2==0)
            ih=iw=1 if fc else rng.choice([1,3,5,7])
            ic=rng.randint(1,31 if fc else 5)
            oc=[1,2,3,4,5,7,8,9,10,11][case%10]
            stride=1 if fc else rng.choice([1,2])
            oh=ow=1 if fc else (ih+stride-1)//stride
            ib=2048+(case%4); ob=4096+((case//4)%4)
            wb=512; bb=1536; mb=1600; sb=1664
            iz=rng.choice([0,17,127,255]); oz=rng.choice([0,10,75,127])
            qmax=rng.choice([127,255]); relu=(case%4==0)
            flags=int(fc)|(2 if relu else 0)|(4 if packed else 0)
            terms=ic*(1 if fc else 9)
            mem=bytearray([0xa5]*8192)
            weights=[[rng.randint(-128,127) for _ in range(terms)] for _ in range(oc)]
            for co in range(oc):
                for term in range(terms):
                    wa=wb+(((co//4)*terms+term)*4+co%4 if packed else co*terms+term)
                    mem[wa]=weights[co][term]&255
            # Packed tail bytes retain the deliberate 0xa5 fill: RTL must mask them.
            inputs=[rng.randint(0,255) for _ in range(ih*iw*ic)]
            mem[ib:ib+len(inputs)]=bytes(inputs)
            biases=[]; multipliers=[]; shifts=[]
            for co in range(oc):
                b=rng.choice([0,0x7fffffff,-0x80000000,rng.randint(-10000,10000)])
                shift=[0,1,31,63][(case+co)%4]
                mult=1 if shift<=1 else rng.randint(1,0x7fffffff)
                biases.append(b); multipliers.append(mult); shifts.append(shift)
                struct.pack_into('<i',mem,bb+co*4,b)
                struct.pack_into('<i',mem,mb+co*4,mult)
                mem[sb+co]=shift
            struct.pack_into('<9I',mem,0,ib,ob,wb,bb,mb,sb,
                ih|(iw<<8)|(ic<<16)|(oc<<24),oh|(ow<<8)|(stride<<16)|(flags<<24),
                iz|(oz<<8)|(qmax<<16))
            gold=bytearray(mem)
            for co in range(oc):
                for y in range(oh):
                    for x in range(ow):
                        acc=biases[co]
                        for ci in range(ic):
                            for ky in range(1 if fc else 3):
                                for kx in range(1 if fc else 3):
                                    yy,xx=y*stride+ky-1,x*stride+kx-1
                                    a=inputs[ci] if fc else (inputs[ci*ih*iw+yy*iw+xx] if 0<=yy<ih and 0<=xx<iw else iz)
                                    term=ci if fc else ci*9+ky*3+kx
                                    acc=i32(acc+(a-iz)*weights[co][term])
                        p=acc*multipliers[co]; s=shifts[co]
                        scaled=i32((p+(1<<(s-1)))>>s) if s else i32(p)
                        q=i32(scaled+oz)
                        if relu:q=max(q,oz)
                        gold[ob+co*oh*ow+y*ow+x]=min(max(q,0),qmax)
            source.write(''.join(f'{w:08x}\n' for w in struct.unpack('<2048I',mem)))
            expected.write(''.join(f'{w:08x}\n' for w in struct.unpack('<2048I',gold)))
            records.append(dict(case=case,packed=packed,fc=fc,ih=ih,ic=ic,oc=oc,stride=stride))
    (folder/'cases.json').write_text(json.dumps(dict(seed=args.seed,cases=records),indent=2))
    print(f'Random NPU stress: {args.cases} cases, seed={args.seed}, full SRAM preservation golden')
if __name__=='__main__':main()
