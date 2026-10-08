"""Check current four-identical-node RTL, gate and routed FPGA evidence."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'reports/noc'
BUILD = ROOT / 'build/noc'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

required = [
    'NOC partial-byte, segmented DMA, self-route and busy protection PASS',
    'NOC concurrent crossing writes / cyclic remote reads under link backpressure PASS',
    'NOC identical nodes with DDR enabled at either node 1 or 3 PASS',
    'NOC partial commit accounting / DDR error trailer PASS',
    'NOC local bounds, unreachable destination, remote bounds, absent DDR and DDR bus errors PASS',
    'NOC CPU MMIO configuration / network DMA / WFI IRQ21 PASS',
    'NOC timeout quarantine / independent response VN progress PASS',
    'NOC late ACK/read response drained without resurrecting command or writing SRAM PASS',
    'NOC DMA concurrently shares SRAM with active CNN, disjoint buffers PASS',
    'NOC boot -> Tiny MNIST -> routed logits/classification PASS',
]
summaries = {}
logs = {'rtl': BUILD/'mesh.log', 'small_rtl': BUILD/'small_mesh.log',
        'gate': BUILD/'gate/noc_gate.log'}
for name, path in logs.items():
    log = path.read_text()
    for marker in required:
        assert marker in log, (name, marker)
    match = re.search(r'NOC MESH PASS identical_nodes=(\d+) topology=2x2 checks=(\d+) acknowledged_commands=(\d+) ddr_requests=(\d+) cycles=(\d+)', log)
    assert match, name
    nodes, checks, commands, ddr, cycles = map(int, match.groups())
    assert (nodes, checks, commands, ddr) == (4, 481, 23, 48), name
    summaries[name] = dict(identical_nodes=nodes, checks=checks,
                          acknowledged_commands=commands, ddr_requests=ddr, cycles=cycles)
assert summaries['rtl'] == summaries['gate']
original = (REPORT/'node_synth.v').read_text().split('`timescale', 1)[1]
converted = (BUILD/'gate/netlist_for_sim.v').read_text().split('`timescale', 1)[1]
converted, count = re.subn(r'\bmodule noc_node_netlist\b', 'module npu_noc_soc', converted)
assert count == 1 and converted == original, 'gate logic must match synthesis'
manifest = json.loads((REPORT/'synthesis_inputs.json').read_text())
for name, expected in manifest.items():
    assert digest(Path(name)) == expected, name
asic = (ROOT/'build/asic_sources.f').read_text()
assert 'npu_noc_core.sv' in asic
for excluded in ['sram_ff.sv', 'npu_soc.sv', 'npu_noc_soc.sv']:
    assert excluded not in asic, excluded
assert '%Error' not in (BUILD/'asic_lint.log').read_text()
xdc = (ROOT/'constraints/noc_ooc.xdc').read_text()
assert '-period 20.000' in xdc and 'set_input_delay -clock sys_clk 2.000' in xdc
assert 'set_false_path -from [get_ports {node_x_i[*] node_y_i[*] port_enable_i[*] mesh_width_i[*] mesh_height_i[*] ddr_present_i}]' in xdc
util = (REPORT/'utilization_routed.rpt').read_text()
def used(label):
    return int(re.search(r'\|\s*'+re.escape(label)+r'\*?\s*\|\s*(\d+)', util).group(1))
resources = {label: used(label) for label in ['Slice LUTs', 'Slice Registers', 'LUT as Memory', 'RAMB36/FIFO*', 'RAMB18', 'DSPs']}
assert resources['RAMB36/FIFO*'] == 2 and resources['RAMB18'] == 0 and resources['LUT as Memory'] == 0
text = (REPORT/'timing_routed.rpt').read_text()
match = re.search(r'WNS\(ns\).*?\n\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)', text, re.S)
wns, tns, whs, ths = map(float, match.groups())
assert wns >= 0 and whs >= 0 and tns == 0 and ths == 0
assert not re.search(r'\|\s*(Error|Critical Warning)\s*\|', (REPORT/'drc_routed.rpt').read_text())
baseline = json.loads((ROOT/'reports/mnist_validation.json').read_text())
files = list((ROOT/'rtl').glob('*.sv')) + list((ROOT/'noc').glob('*.py'))
files += list((ROOT/'scripts').glob('*noc*'))
files += [ROOT/'tb/tb_noc_mesh.sv', ROOT/'sw/npu.h', ROOT/'constraints/noc_ooc.xdc',
          ROOT/'mnist/artifacts/noc_boot.hex', ROOT/'mnist/artifacts/sram7.hex',
          ROOT/'build/asic_sources.f', REPORT/'synthesis_inputs.json',
          REPORT/'node_synth.v', REPORT/'node_routed.dcp',
          REPORT/'utilization_routed.rpt', REPORT/'timing_routed.rpt',
          REPORT/'drc_routed.rpt', BUILD/'gate/gate_port_adapter.sv', BUILD/'asic_lint.log']
files += list((ROOT/'mnist/artifacts').glob('gold7*.hex')) + list(logs.values())
result = dict(part='xc7a35tcsg324-1', vivado='2025.2', clock_mhz=50,
    topology='2x2', identical_node_hardware=True,
    configurations=[dict(router_depth=2, packet_words=16), dict(router_depth=1, packet_words=4)],
    resources=resources, additional_resources={k: resources[k]-baseline['resources'][k] for k in resources},
    wns_ns=wns, whs_ns=whs, tests=summaries, tiny_mnist_prediction=7,
    cnn_concurrent_network_dma_verified=True, cpu_network_dma_irq21_verified=True,
    sram_bytes_per_node=8192, extra_sram=False, network_dma='native NMC transactions',
    ddr_service_model_only=True, physical_link_verified=False,
    ddr_controller_phy_verified=False, asic_area_verified=False,
    source_and_evidence_sha256={str(p.relative_to(ROOT)): digest(p) for p in files})
(REPORT/'validation.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({k: v for k, v in result.items() if k != 'source_and_evidence_sha256'}, indent=2))
