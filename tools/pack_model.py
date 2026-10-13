"""Repack the exported INT8 checkpoint for a 32-bit single-port vector NPU.

The source image and PyTorch outputs are unchanged. Descriptor flag bit2
selects [output_channel//4][input_term][output_channel%4], with zero-filled
tail lanes. Activation tensors remain CHW. No PyTorch or quantization is
performed here; the script only permutes bytes already quantized offline.
"""
import json
import struct
from pathlib import Path
from build_firmware import integer_golden

ROOT = Path(__file__).resolve().parents[1]

def main():
    src = ROOT / 'cnn_npu_int8/generated/8k'
    dst = ROOT / 'cnn_npu_int8/generated/8k-p4'
    meta = json.loads((src/'golden.json').read_text())
    original = bytes(int(x, 16) for x in (src/'cnn_npu_mem.hex').read_text().split())
    mem = bytearray(len(original))
    cursor = 0
    descriptors = []
    layers = []
    for index, old_meta in enumerate(meta['layers']):
        d = list(struct.unpack_from('<9I', original, meta['descriptor_base']+index*36))
        src_base, dst_base, wb, bb, mb, sb, shape, out, quant = d
        ic, oc = (shape>>16)&255, shape>>24
        flags = out>>24
        terms = ic*(1 if flags&1 else 9)
        wbase = cursor
        packed = bytearray(((oc+3)//4)*terms*4)
        for co in range(oc):
            for term in range(terms):
                packed[((co//4)*terms+term)*4+co%4] = original[wb+co*terms+term]
        mem[cursor:cursor+len(packed)] = packed
        cursor += len(packed)
        bases = [wbase]
        for base, size in ((bb,4*oc),(mb,4*oc),(sb,oc)):
            cursor = (cursor+3)&~3
            bases.append(cursor)
            mem[cursor:cursor+size] = original[base:base+size]
            cursor += size
        cursor = (cursor+3)&~3
        d[2:6] = bases
        d[7] |= 4<<24
        descriptors.append(d)
        lm = dict(old_meta)
        lm.update(dict(zip(('weight','bias','multiplier','shift'),bases)))
        lm['weight_layout'] = 'oc4-term-lane'
        layers.append(lm)
    if cursor > meta['activation_a']:
        raise RuntimeError(f'Packed parameters overlap activations: {cursor}')
    for index,d in enumerate(descriptors):
        struct.pack_into('<9I',mem,meta['descriptor_base']+index*36,*d)
    a = meta['activation_a']
    mem[a:a+len(meta['input_codes'])] = bytes(meta['input_codes'])
    packed_meta = dict(meta, lanes=4, weight_layout='oc4-term-lane',
                       parameter_bytes=cursor, layers=layers)
    assert integer_golden(original,meta) == integer_golden(mem,packed_meta), 'Repacking changes golden'
    dst.mkdir(parents=True,exist_ok=True)
    (dst/'golden.json').write_text(json.dumps(packed_meta,indent=2)+'\n')
    (dst/'cnn_npu_mem.hex').write_text(''.join(f'{v:02x}\n' for v in mem))
    (dst/'npu_word.hex').write_text(''.join(f'{w:08x}\n' for w in struct.unpack('<2048I',mem)))
    (dst/'input_codes.hex').write_text((src/'input_codes.hex').read_text())
    (dst/'golden.svh').write_text((src/'golden.svh').read_text())
    print(f'Packed model: parameters={cursor} bytes / SRAM={len(mem)}, all 6 integer layers unchanged')

if __name__ == '__main__':
    main()
