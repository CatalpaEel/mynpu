"""Check source provenance and regenerate the independent integer reference."""
import hashlib
import json
from pathlib import Path
from build_firmware import integer_golden

ROOT=Path(__file__).resolve().parents[1]

def main():
    records=json.loads((ROOT/'third_party/lab3/SOURCE_MANIFEST.json').read_text())
    for item in records:
        path=ROOT/'third_party/lab3'/item['path']
        assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'], path
    print(f'lab3: {len(records)} imported files match original SHA256')
    for layout in ('8k','16k','8k-p4'):
        folder=ROOT/f'cnn_npu_int8/generated/{layout}'
        meta=json.loads((folder/'golden.json').read_text())
        image=bytes(int(v,16) for v in (folder/'cnn_npu_mem.hex').read_text().split())
        layers=integer_golden(image,meta)
        generated=ROOT/'generated'/layout
        integer_hex=bytes(int(v,16) for v in (generated/'integer_layers.hex').read_text().split())
        assert integer_hex==bytes(v for layer in layers for v in layer)
        pytorch=meta['pytorch_layer_codes']+[meta['expected_output_codes']]
        pytorch_hex=bytes(int(v,16) for v in (generated/'pytorch_layers.hex').read_text().split())
        assert pytorch_hex==bytes(v for layer in pytorch for v in layer)
        cpu=[int(v,16) for v in (generated/'cpu.hex').read_text().split()]
        assert len(cpu)==2048 and cpu[0]==0x00002117, 'Invalid CPU image/entry'
        for index,(a,b) in enumerate(zip(layers,pytorch)):
            assert len(a)==len(b)
            delta=[abs(x-y) for x,y in zip(a,b)]
            assert max(delta)<=1
            print(f'{layout} layer {index}: {len(a)} codes, {sum(d!=0 for d in delta)} PyTorch differences, max={max(delta)}')
    print('Asset checks PASS')

if __name__=='__main__': main()
