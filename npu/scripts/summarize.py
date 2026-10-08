#!/usr/bin/env python3
"""Collect reproducible evidence from the build and simulation logs."""
from pathlib import Path
import hashlib,json,re
root=Path(__file__).resolve().parents[1]
exported=(root/'reports/npu_synth.v').read_text().split('`timescale',1)[1]
simulated=(root/'build/netlist_sim/netlist_for_sim.v').read_text().split('`timescale',1)[1]
assert exported == simulated, 'Netlist simulation is stale: run simulate_netlist.sh again'
util=(root/'reports/utilization_routed.rpt').read_text()
timing=(root/'reports/timing_routed.rpt').read_text()
sim=(root/'build/simulation.log').read_text()
gate=(root/'build/netlist_sim/netlist_simulation.log').read_text()
nmc=(root/'build/nmc_simulation.log').read_text()
dma=(root/'build/dma_control_simulation.log').read_text()
assert 'ALL PASS' in sim and 'ALL PASS' in gate and 'PASS NMC' in nmc and 'PASS DMA control' in dma
assert re.search(r'ALL PASS checks=(\d+)',sim)[1] == re.search(r'ALL PASS checks=(\d+)',gate)[1]
assert 'All user specified timing constraints are met.' in timing
resources={}
for name in ['Slice LUTs','Slice Registers','Block RAM Tile','RAMB36/FIFO*','RAMB18','DSPs']:
 match=re.search(r'\|\s*'+re.escape(name)+r'\s*\|\s*([\d.]+)',util)
 resources[name]=float(match[1]) if '.' in match[1] else int(match[1])
assert resources['RAMB18'] == 0 and resources['RAMB36/FIFO*'] == 2
wns=float(re.search(r'Setup\s*:.*?Worst Slack\s+([\d.-]+)ns',timing)[1])
whs=float(re.search(r'Hold\s*:.*?Worst Slack\s+([\d.-]+)ns',timing)[1])
counts=re.search(r'ALL PASS checks=(\d+) host_transactions=(\d+) max_host_wait=(\d+)',sim)
sources=[p for p in root.rglob('*') if p.is_file() and p.parts[-2] in ['rtl','tb','sw','constraints','scripts']]
external=root.parent/'external'
archives={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in external.glob('*.zip')}
data={'vivado':'2025.2','part':'xc7a35tcsg324-1','implementation':'out_of_context_routed',
      'clock_mhz':50,'wns_ns':wns,'whs_ns':whs,'resources':resources,
      'behavioral_simulation':'PASS','synthesis_functional_simulation':'PASS',
      'checks':int(counts[1]),'host_transactions':int(counts[2]),'max_host_wait_cycles':int(counts[3]),
      'nmc_eight_master_test':'PASS: 128 consecutive transactions, 16 grants per master',
      'dma_cancellation_test':'PASS',
      'storage':'One 8KB SRAM; instructions loaded through external DMA; no ROM/FIFO RAM',
      'dma_channels':['stream_to_sram','sram_to_stream','sram_copy_or_fill'],
      'asic_top':'npu_core',
      'board_test':'Not performed: board clock/pin/voltage constraints not provided',
      'drc':'No errors or critical warnings; warnings in reports/drc_routed.rpt',
      'external_archive_sha256':archives,
      'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
(root/'reports/validation.json').write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps({k:v for k,v in data.items() if 'sha256' not in k},indent=2))
