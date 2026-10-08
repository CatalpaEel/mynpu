"""Collect evidence only after the current RTL, gate simulation and route pass."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1];REPORT=ROOT/'reports';BUILD=ROOT/'build'
meta=json.loads((ROOT/'mnist/artifacts/model.json').read_text())
rtl=(BUILD/'mnist_simulation.log').read_text();gate=(BUILD/'mnist_gate/mnist_gate.log').read_text();legacy=(BUILD/'legacy_regression.log').read_text()
assert 'MNIST PASS samples=10' in rtl and 'normal mode without host layer ACK PASS' in rtl
assert 'CNN busy descriptor protection / shared master exclusion PASS' in rtl
assert 'CNN boundary cases PASS' in rtl and 'MNIST PASS samples=1' in gate
assert 'PASS NMC MMIO:' in legacy
assert 'ALL PASS checks=1228' in legacy and 'PASS NMC:' in legacy and 'PASS DMA control:' in legacy
stream=(BUILD/'mnist_stream.log').read_text()
sm=re.search(r'STREAM PASS frames=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)',stream)
assert sm, 'multi-image stream simulation must pass'
frames,macs,kernel_cycles,elapsed_cycles=map(int,sm.groups())
assert frames==20 and macs==frames*40770
overlap=re.search(r'rx_overlap_beats=(\d+) tx_overlap_beats=(\d+)',stream)
rx_overlap,tx_overlap=map(int,overlap.groups());assert rx_overlap>0 and tx_overlap>0
single=(BUILD/'mnist_latency.log').read_text()
baseline=(BUILD/'baseline_single_v4/mnist_latency.log').read_text()
def single_records(log):
 rows=re.findall(r'SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)',log)
 assert len(rows)==10 and 'SINGLE PASS samples=10' in log
 return [dict(sample=int(i),useful_macs=int(m),kernel_cycles=int(k),elapsed_cycles=int(e)) for i,m,k,e in rows]
single_rows=single_records(single);baseline_rows=single_records(baseline)
for current,old in zip(single_rows,baseline_rows):
 assert current['sample']==old['sample'] and current['useful_macs']==40770
 assert 40770<=current['kernel_cycles']<=current['elapsed_cycles']<old['elapsed_cycles']
 assert 100*40770/current['kernel_cycles']>99
input_rows=re.findall(r'SINGLE_INPUT sample=(\d+) ingress_cycles=(\d+) input_to_classification_cycles=(\d+)',single)
assert len(input_rows)==10 and 'SINGLE PASS samples=10 checks=150' in single
for (i,ingress,total),current in zip(input_rows,single_rows):
 assert int(i)==current['sample'] and int(total)==int(ingress)+current['elapsed_cycles'] and int(ingress)>0
input_stats=dict(images=10,input_bytes=784,rx_interface='32bit valid/ready, continuous offered data',
 ingress_cycles=int(input_rows[0][1]),input_to_classification_cycles=int(input_rows[0][2]),
 input_to_classification_us_at_50mhz=int(input_rows[0][2])/50,includes_rx_dma_setup_and_input_loading=True,
 excludes_boot_and_model_loading=True)
single_stats=dict(samples=10,host_polling=False,layer_ack=False,includes_cpu_configuration_and_argmax=True,
 excludes_boot_model_and_input_loading=True,clock_mhz=50,
 baseline_elapsed_cycles=baseline_rows[0]['elapsed_cycles'],elapsed_cycles_min=min(x['elapsed_cycles'] for x in single_rows),
 elapsed_cycles_max=max(x['elapsed_cycles'] for x in single_rows),kernel_cycles=single_rows[0]['kernel_cycles'],
 kernel_utilization_pct=100*40770/single_rows[0]['kernel_cycles'],system_utilization_pct=100*40770/single_rows[0]['elapsed_cycles'],
 latency_us_at_50mhz=single_rows[0]['elapsed_cycles']/50,
 input_transfer_inclusive=input_stats,latency_reduction_pct=100*(1-single_rows[0]['elapsed_cycles']/baseline_rows[0]['elapsed_cycles']),results=single_rows)
stream_meta=json.loads((ROOT/'mnist/artifacts/stream.json').read_text())
assert stream_meta['cache_data_bytes']==128
assert (BUILD/'mnist_gate/netlist_for_sim.v').read_text().split('`timescale',1)[1]==(REPORT/'npu_synth.v').read_text().split('`timescale',1)[1]
manifest=json.loads((REPORT/'synthesis_inputs.json').read_text())
for name,digest in manifest.items():assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
u=(REPORT/'utilization_routed.rpt').read_text();t=(REPORT/'timing_routed.rpt').read_text();d=(REPORT/'drc_routed.rpt').read_text()
def used(label):
 return int(re.search(r'\|\s*'+re.escape(label)+r'\*?\s*\|\s*(\d+)',u).group(1))
resources={k:used(k) for k in ['Slice LUTs','Slice Registers','LUT as Memory','RAMB36/FIFO*','RAMB18','DSPs']}
assert resources['RAMB36/FIFO*']==2 and resources['RAMB18']==0
assert used('LUT as Memory')==0
m=re.search(r'WNS\(ns\).*?\n\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)',t,re.S)
wns,tns,whs,ths=map(float,m.groups());assert wns>=0 and whs>=0 and tns==0 and ths==0
assert not re.search(r'\|\s*(Error|Critical Warning)\s*\|',d)
checkpoint=ROOT.parent/'external/tiny_MNIST/outputs/pool-stride2-fp32-int8/model_int8.pt'
assert hashlib.sha256(checkpoint.read_bytes()).hexdigest()==meta['checkpoint_sha256']
files=list((ROOT/'rtl').glob('*.sv'))+list((ROOT/'mnist').glob('*.py'))+list((ROOT/'mnist/artifacts').glob('*.hex'))+[ROOT/'tb/tb_mnist.sv',ROOT/'tb/tb_mnist_latency.sv',ROOT/'tb/tb_mnist_stream.sv',ROOT/'tb/tb_nmc.sv',ROOT/'tb/tb_npu_soc.sv',ROOT/'sw/npu.h',ROOT/'mnist/artifacts/stream.json',ROOT/'mnist/artifacts/model.json',checkpoint]
files+=list((BUILD/'baseline_single_v4').glob('*'))
files+=list((ROOT/'scripts').glob('simulate*.sh'))+[ROOT/'scripts/build_vivado.sh',ROOT/'scripts/build_vivado.tcl']
hashes={str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
result=dict(part='xc7a35tcsg324-1',vivado='2025.2',clock_mhz=50,resources=resources,wns_ns=wns,whs_ns=whs,
 local_pytorch_accuracy=meta['local_pytorch_test_accuracy'],fixed_point_reference_accuracy=meta['fixed_point_reference_test_accuracy'],
 fixed_point_vs_pytorch_prediction_disagreements=meta['fixed_point_vs_pytorch_prediction_disagreements'],software_test_images=10000,
 rtl_test_images=10,stream_test_images=frames,single_image_latency=single_stats,register_working_set_bytes=128,
 stream_useful_macs=macs,stream_kernel_cycles=kernel_cycles,stream_elapsed_cycles=elapsed_cycles,
 stream_kernel_utilization_pct=100*macs/kernel_cycles,stream_system_utilization_pct=100*macs/elapsed_cycles,
 rx_overlap_beats=rx_overlap,tx_overlap_beats=tx_overlap,asic_area_verified=False,normal_mode_extra_inference=True,gate_test_images=1,rtl_result=re.search(r'MNIST PASS samples=.*',rtl).group(0),
 gate_result=re.search(r'MNIST PASS samples=.*',gate).group(0),layer_output_byte_checks=17940,model_samples=meta['samples'],sha256=hashes)
(REPORT/'mnist_validation.json').write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k not in ('sha256','model_samples')},indent=2))
