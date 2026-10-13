"""Build a freestanding RV32IMC CPU self-test and independent integer golden.

No PyTorch dependency: uses the exported checkpoint memory image and recorded
FBGEMM output. Model regeneration itself is tools/export_model.py (PyTorch).
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def integer_golden(image, metadata):
    mem = bytearray(image)
    outputs = []
    for i in range(6):
        d = struct.unpack_from('<9I', mem, metadata['descriptor_base'] + i * 36)
        src, dst, wb, bb, mb, sb, shape, out, quant = d
        ih, iw, ic, oc = [(shape >> (8*k)) & 255 for k in range(4)]
        oh, ow, stride, flags = [(out >> (8*k)) & 255 for k in range(4)]
        iz, oz, qmax = [(quant >> (8*k)) & 255 for k in range(3)]
        values = []
        for co in range(oc):
            bias = struct.unpack_from('<i', mem, bb + 4*co)[0]
            multiplier = struct.unpack_from('<i', mem, mb + 4*co)[0]
            shift = mem[sb+co]
            for y in range(oh):
                for x in range(ow):
                    acc = bias
                    for ci in range(ic):
                        for ky in range(1 if flags & 1 else 3):
                            for kx in range(1 if flags & 1 else 3):
                                if flags & 1:
                                    a = mem[src+ci]
                                    wa = wb+co*ic+ci
                                else:
                                    yy, xx = y*stride+ky-1, x*stride+kx-1
                                    a = mem[src+ci*ih*iw+yy*iw+xx] if 0 <= yy < ih and 0 <= xx < iw else iz
                                    wa = wb+((co*ic+ci)*3+ky)*3+kx
                                if flags & 4:
                                    terms = ic * (1 if flags & 1 else 9)
                                    term = ci if flags & 1 else ci*9+ky*3+kx
                                    wa = wb + ((co//4)*terms+term)*4 + co%4
                                w = mem[wa] if mem[wa] < 128 else mem[wa]-256
                                acc += (a-iz)*w
                    acc = ((acc+(1 << 31)) % (1 << 32))-(1 << 31)
                    p = acc*multiplier
                    q = ((p + (1 << (shift-1))) >> shift) if shift else p
                    q += oz
                    if flags & 2:
                        q = max(q, oz)
                    values.append(min(max(q, 0), qmax))
        mem[dst:dst+len(values)] = bytes(values)
        outputs.append(values)
    return outputs

def c_words(name, data):
    data = bytes(data)
    data += bytes((-len(data)) % 4)
    words = struct.unpack('<'+'I'*(len(data)//4), data)
    lines = [', '.join(f'0x{w:08x}u' for w in words[i:i+8]) for i in range(0, len(words), 8)]
    return f'static const unsigned int {name}[] = {{\n  '+',\n  '.join(lines)+'\n};\n'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--layout', choices=['8k','16k','8k-p4'], default='8k')
    ap.add_argument('--gcc', default=os.environ.get('RISCV_GCC', 'riscv64-unknown-elf-gcc'))
    ap.add_argument('--objcopy', default=os.environ.get('RISCV_OBJCOPY'))
    args = ap.parse_args()
    meta = json.loads((ROOT/f'cnn_npu_int8/generated/{args.layout}/golden.json').read_text())
    image = bytes(int(x, 16) for x in (ROOT/f'cnn_npu_int8/generated/{args.layout}/cnn_npu_mem.hex').read_text().split())
    layers = integer_golden(image, meta)
    out = ROOT/'generated'/args.layout
    out.mkdir(parents=True, exist_ok=True)
    header = '#pragma once\n'
    header += f'#define DESC_BASE {meta["descriptor_base"]}u\n#define INPUT_BASE {meta["activation_a"]}u\n#define OUTPUT_BASE {meta["activation_a"]}u\n'
    ends = []
    for i, layer in enumerate(meta['layers']):
        d = struct.unpack_from('<9I', image, meta['descriptor_base']+36*i)
        oc = d[6] >> 24
        ends += [d[3]+oc*4, d[4]+oc*4, d[5]+oc]
    param_end = (max(ends)+3)//4*4
    header += c_words('model_params', image[:param_end])
    header += c_words('model_desc', image[meta['descriptor_base']:meta['descriptor_base']+216])
    header += c_words('model_input', bytes(meta['input_codes']))
    header += 'static const unsigned char integer_output[10] = {'+','.join(map(str,layers[-1]))+'};\n'
    header += 'static const unsigned char pytorch_output[10] = {'+','.join(map(str,meta['expected_output_codes']))+'};\n'
    (out/'model_data.h').write_text(header)
    (out/'integer_layers.hex').write_text(''.join(f'{v:02x}\n' for layer in layers for v in layer))
    pytorch_layers=meta['pytorch_layer_codes']+[meta['expected_output_codes']]
    (out/'pytorch_layers.hex').write_text(''.join(f'{v:02x}\n' for layer in pytorch_layers for v in layer))
    (out/'integer_golden.json').write_text(json.dumps({'layout':args.layout, 'pytorch_output':meta['expected_output_codes'], 'integer_output':layers[-1], 'layers':layers},indent=2))
    gcc = shutil.which(args.gcc) or args.gcc
    objcopy = args.objcopy or str(Path(gcc).with_name(Path(gcc).name.replace('gcc','objcopy')))
    build = ROOT/'build'/args.layout
    build.mkdir(parents=True, exist_ok=True)
    elf = build/'firmware.elf'
    subprocess.run([gcc, '-march=rv32imc_zicsr', '-mabi=ilp32', '-Os', '-g', '-ffreestanding', '-fno-builtin',
                    '-fno-pic', '-msmall-data-limit=0', '-nostdlib', '-Wl,--build-id=none', '-Wl,--no-relax', '-Wl,--gc-sections',
                    '-T', (ROOT/'sw/linker.ld').as_posix(), '-I', out.as_posix(), (ROOT/'sw/startup.S').as_posix(),
                    (ROOT/'sw/main.c').as_posix(), '-o', elf.as_posix()], check=True)
    binary = build/'firmware.bin'
    subprocess.run([objcopy, '-O', 'binary', elf.as_posix(), binary.as_posix()], check=True)
    data = binary.read_bytes()
    if len(data) > 0x1bc0:
        raise RuntimeError(f'Firmware {len(data)} bytes overlaps reserved stack')
    padded = data + bytes(8192-len(data))
    (out/'cpu.hex').write_text(''.join(f'{w:08x}\n' for w in struct.unpack('<2048I', padded)))
    print(json.dumps({'layout':args.layout,'firmware_bytes':len(data),'parameter_bytes':param_end,
                      'integer_output':layers[-1],'pytorch_output':meta['expected_output_codes']},indent=2))

if __name__ == '__main__':
    main()
