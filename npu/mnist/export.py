"""Export supplied per-channel affine checkpoint; no training or recalibration."""
import ast,gzip,json,struct,urllib.request,hashlib
from pathlib import Path
import numpy as np
import torch
ROOT=Path(__file__).resolve().parent; EXT=ROOT.parents[1]/'external/tiny_MNIST'; OUT=ROOT/'artifacts'; OUT.mkdir(exist_ok=True)
torch.set_num_threads(4)
ns={'nn':torch.nn}; tree=ast.parse((EXT/'main_mnist.py').read_text()); exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='Net'],type_ignores=[]),'Net','exec'),ns)
import importlib.util
spec=importlib.util.spec_from_file_location('quantize',EXT/'quantize.py'); q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
c=torch.load(EXT/'outputs/pool-stride2-fp32-int8/model_int8.pt',weights_only=False)
p=q.build_quantized_model(ns['Net'](),torch,c['backend']);p(torch.zeros(1,1,28,28));model=torch.ao.quantization.convert(p).eval();model.load_state_dict(c['state_dict'])
for name in ['t10k-images-idx3-ubyte','t10k-labels-idx1-ubyte']:
 f=OUT/(name+'.gz')
 if not f.exists(): urllib.request.urlretrieve('https://storage.googleapis.com/cvdf-datasets/mnist/'+name+'.gz',f)
images=np.frombuffer(gzip.decompress((OUT/'t10k-images-idx3-ubyte.gz').read_bytes()),np.uint8,offset=16).reshape(-1,1,28,28)
labels=np.frombuffer(gzip.decompress((OUT/'t10k-labels-idx1-ubyte.gz').read_bytes()),np.uint8,offset=8)
blob=bytearray(); layers=[]; ins=float(model.quant.scale); iz=int(model.quant.zero_point)
def put(data):
 while len(blob)%4:blob.append(0)
 addr=0x80000400+len(blob);blob.extend(data);return addr
def rnd(x):
 q=x>>24;r=x-(q<<24);return q+((r>(1<<23))|((r==(1<<23))&((q&1)!=0)))
for i,name in enumerate(['conv1','conv2','conv3','conv4','conv5','fc1']):
 op=getattr(model.model,name);op=op[0] if i<5 else op
 w=op.weight(); wz=w.q_per_channel_zero_points().numpy();assert np.all(wz==0)
 ws=w.q_per_channel_scales().numpy(); ow=float(op.scale);oz=int(op.zero_point)
 weights=w.int_repr().numpy(); mf=np.rint(ins*ws/ow*(1<<24));bf=np.rint(op.bias().detach().numpy().astype(float)/ow*(1<<24));assert np.all((mf>=0)&(mf<2**31)) and np.all((bf>=-2**31)&(bf<2**31));multip=mf.astype('<i4');bias=bf.astype('<i4')
 wa=put(weights.tobytes());qa=put(np.stack([multip,bias],axis=1).tobytes())
 layers.append(dict(name=name,weights=wa,quant=qa,in_scale=ins,in_zero=iz,out_scale=ow,out_zero=oz,shape=list(weights.shape),stride=2 if i in [0,2,3] else 1))
 ins=ow;iz=oz
(OUT/'params.hex').write_text(''.join(f'{v:02x}\n' for v in blob))
meta={'checkpoint_sha256':hashlib.sha256((EXT/'outputs/pool-stride2-fp32-int8/model_int8.pt').read_bytes()).hexdigest(),'source_revision':'22f3555','layers':layers,'parameter_bytes':len(blob),'checkpoint_accuracy':c['int8_accuracy'],'samples':[],'input_scale':float(model.quant.scale),'input_zero':int(model.quant.zero_point)}
for digit in range(10):
 idx=int(np.flatnonzero(labels==digit)[0]);x=torch.from_numpy(images[idx:idx+1].copy()).float();x=(x/255-.1307)/.3081
 a=model.quant(x).int_repr().numpy().astype(np.int64)[0];(OUT/f'input{digit}.hex').write_text(''.join(f'{v:02x}\n' for v in a.flatten()))
 ref=model.quant(x);maxdiff=[]
 for i,L in enumerate(layers):
  op=getattr(model.model,L['name']);op=op[0] if i<5 else op;w=op.weight().int_repr().numpy().astype(np.int64)
  if i<5:
   h=a.shape[1];out=3 if i==3 else (h+L['stride']-1)//L['stride'];pad=np.pad(a-L['in_zero'],((0,0),(1,1),(1,1)))
   acc=np.empty((w.shape[0],out,out),np.int64)
   for yy in range(out):
    for xx in range(out):acc[:,yy,xx]=(w*pad[:,yy*L['stride']:yy*L['stride']+3,xx*L['stride']:xx*L['stride']+3]).sum(axis=(1,2,3))
   ref=getattr(model.model,L['name'])(ref)
   if i==3:ref=ref[:,:,:3,:3]
  else:acc=w@(a.flatten()-L['in_zero']);ref=op(ref.reshape(1,-1));out=1
  off=L['quant']-0x80000400;m,b=np.frombuffer(blob[off:off+8*w.shape[0]],'<i4').reshape(-1,2).T
  shape=(-1,1,1) if i<5 else (-1,);a=np.clip(rnd(acc*m.reshape(shape)+b.reshape(shape))+L['out_zero'],L['out_zero'] if i<5 else 0,255)
  diff=int(np.max(np.abs(a-ref.int_repr().numpy()[0].astype(np.int64))));maxdiff.append(diff)
  (OUT/f'gold{digit}_{i}.hex').write_text(''.join(f'{v:02x}\n' for v in a.flatten()))
 pred=int(a.argmax());ptpred=int(ref.int_repr().argmax());assert pred==ptpred,(digit,pred,ptpred)
 meta['samples'].append(dict(index=idx,label=digit,prediction=pred,pytorch_prediction=ptpred,layer_max_lsb_difference=maxdiff))
 print('sample',digit,'index',idx,'prediction',pred,'max LSB',maxdiff,flush=True)
correct=0
with torch.no_grad():
 for first in range(0,len(images),512):
  x=torch.from_numpy(images[first:first+512].copy()).float();x=(x/255-.1307)/.3081
  correct+=int((model(x).argmax(1).numpy()==labels[first:first+512]).sum())
meta['local_pytorch_test_accuracy']=100*correct/len(images);meta['local_test_count']=len(images)
fixed_correct=0;disagreements=0
with torch.no_grad():
 for first in range(0,len(images),256):
  x=torch.from_numpy(images[first:first+256].copy()).float();x=(x/255-.1307)/.3081
  a=model.quant(x).int_repr().to(torch.int64)
  for i,L in enumerate(layers):
   op=getattr(model.model,L['name']);op=op[0] if i<5 else op
   wt=op.weight().int_repr().double()
   if i<5:
    acc=torch.nn.functional.conv2d((a-L['in_zero']).double(),wt,stride=L['stride'],padding=1).to(torch.int64)
    if i==3:acc=acc[:,:,:3,:3]
    shape=(1,-1,1,1)
   else:
    acc=(a.reshape(a.shape[0],-1)-L['in_zero']).double().matmul(wt.T).to(torch.int64);shape=(1,-1)
   off=L['quant']-0x80000400;params=np.frombuffer(blob[off:off+8*wt.shape[0]],'<i4').reshape(-1,2).copy()
   m=torch.from_numpy(params[:,0]).to(torch.int64).reshape(shape);b=torch.from_numpy(params[:,1]).to(torch.int64).reshape(shape)
   scaled=acc*m+b;quo=scaled>>24;remainder=scaled-(quo<<24)
   a=quo+((remainder>(1<<23))|((remainder==(1<<23))&((quo&1)!=0))).to(torch.int64)+L['out_zero']
   a=a.clamp(L['out_zero'] if i<5 else 0,255)
  pred=a.argmax(1);fixed_correct+=int((pred.numpy()==labels[first:first+256]).sum())
  disagreements+=int((pred!=model(x).argmax(1)).sum())
meta['fixed_point_reference_test_accuracy']=100*fixed_correct/len(images)
meta['fixed_point_vs_pytorch_prediction_disagreements']=disagreements
print('Q24 reference accuracy',meta['fixed_point_reference_test_accuracy'],'prediction disagreements',disagreements,flush=True)

print('Local PyTorch INT8 accuracy',meta['local_pytorch_test_accuracy'],flush=True)
(OUT/'model.json').write_text(json.dumps(meta,indent=2));torch.save(model.state_dict(),OUT/'loaded_state.pt');print('parameter bytes',len(blob))
