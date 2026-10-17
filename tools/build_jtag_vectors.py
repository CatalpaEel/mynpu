"""Record actual PyTorch INT8 and independent integer outputs for Lab6 vectors.

Run in the eeml environment. Board runtime itself needs only Python's stdlib.
Already-quantized input codes are fed directly to the quantized PyTorch model.
"""
import argparse,hashlib,json,struct,sys
from pathlib import Path
import torch
from build_firmware import integer_golden
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--input-hex',type=Path,default=ROOT/'build/mnist-regression/mnist_input_codes_8k-p4.hex')
    p.add_argument('--count',type=int,default=64);a=p.parse_args()
    sys.path.insert(0,str(ROOT/'cnn_npu_int8/tools'))
    from export_model import build_quantized
    checkpoint=ROOT/'model/checkpoints/model_int8.pt'
    state=torch.load(checkpoint,map_location='cpu',weights_only=False)['state_dict']
    model=build_quantized(state).eval()
    source=ROOT/'cnn_npu_int8/generated/8k-p4'
    meta=json.loads((source/'golden.json').read_text())
    memory=bytes(int(v,16) for v in(source/'cnn_npu_mem.hex').read_text().split())
    data=bytes(int(v,16)for v in a.input_hex.read_text().split())
    if a.count<1 or len(data)<a.count*784:raise SystemExit('Not enough quantized inputs')
    vectors=[]
    for i in range(a.count):
        codes=data[i*784:(i+1)*784]
        image=bytearray(memory);image[meta['activation_a']:meta['activation_a']+784]=codes
        integer=integer_golden(image,meta)[-1]
        tensor=torch.tensor(list(codes),dtype=torch.uint8).reshape(1,1,28,28)
        q=torch._make_per_tensor_quantized_tensor(tensor,float(state['quant.scale']),int(state['quant.zero_point']))
        with torch.no_grad():pt=model.model(q).int_repr().flatten().tolist()
        vectors.append(dict(input=list(codes),integer=integer,pytorch=pt))
    indices=ROOT/'build/mnist-regression/mnist_indices_8k-p4.json'
    out=ROOT/'generated/jtag/vectors';out.mkdir(parents=True,exist_ok=True)
    max_error=max(abs(x-y)for v in vectors for x,y in zip(v['integer'],v['pytorch']))
    result=dict(checkpoint_sha256=hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
      input_hex_sha256=hashlib.sha256(a.input_hex.read_bytes()).hexdigest(),
      provenance=json.loads(indices.read_text())if indices.is_file()else {},
      count=len(vectors),pytorch_max_code_error=max_error,vectors=vectors)
    (out/'mnist.json').write_text(json.dumps(result,separators=(',',':'))+'\n',newline='\n')
    for name,key in (('inputs.hex','input'),('integer.hex','integer'),('pytorch.hex','pytorch')):
        values=[q for v in vectors for q in v[key]]
        width=28 if key=='input'else 10
        (out/name).write_text(''.join(' '.join('%02x'%q for q in values[i:i+width])+'\n'
                                    for i in range(0,len(values),width)),newline='\n')
    print('Recorded',len(vectors),'actual PyTorch + integer vectors; max code difference',max_error)
if __name__=='__main__':main()
