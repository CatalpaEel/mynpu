"""Extract only unchanged PE gates; validate public RTL and all library hashes."""
import hashlib,json,re
from pathlib import Path

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def extract(origin,project,libraries):
 m=json.loads((origin/'inputs/source_manifest.json').read_text());name='cnn_npu_int8/rtl/torus_pe.sv'
 if m['file_sha256'].get(name)!=digest(project/name):raise ValueError('Frozen PE RTL mismatch')
 if any(m['library_sha256'].get(str(p))!=digest(p)for p in libraries):raise ValueError('Frozen PE library mismatch')
 block=origin/'mynpu/torus_pe_synth'
 standalone=(block/'torus_pe.postsyn.v').is_file()
 folder=block if standalone else origin/'mynpu/chip_synth'
 log=(folder/'launcher.log').read_text(errors='replace')
 markers=['TORUS_PE_MAPPED_PASS']if standalone else['GRID_FAST_AREA_PASS','GRID_FULL_SYNTHESIS_PASS']
 if'Normal exit.'not in log or not any(x in log.splitlines()for x in markers):raise ValueError('Original mapping did not finish')
 if standalone:
  script=origin/'scripts/synth_torus_pe.tcl'
  if m['script_sha256'].get(script.name)!=digest(script):raise ValueError('Original PE synthesis script changed')
 netlist=folder/('torus_pe.postsyn.v'if standalone else'mynpu_asic_top.postsyn.v')
 matches=re.findall(r'^module torus_pe\(.*?^endmodule\s*$',netlist.read_text(),re.M|re.S)
 if len(matches)!=1:raise ValueError('Cannot identify exactly one mapped PE')
 leaf=matches[0].replace('module torus_pe(', 'module torus_pe_frozen_leaf(',1)
 source=(project/name).read_text();wrapper=source[:source.index(');')+2]+'\n'
 ports=['clk_i','rst_ni','execute_i','operation_i','destination_i','operand_a_i','operand_b_i','load0_i','load1_i','load0_reg_i','load1_reg_i','load0_data_i','load1_data_i','load0_be_i','load1_be_i']
 wrapper+=' torus_pe_frozen_leaf i_leaf('+','.join('.%s(%s)'%(p,p)for p in ports)
 wrapper+=','+','.join('.\\registers_o[%d] (registers_o[%d])'%(i,i)for i in range(4))+');\nendmodule\n'
 # The extracted block must contain only technology cells, not hidden RTL deps.
 if re.search(r'^\s*(?:CDN_|torus_|mynpu_)\w*\s+\w+\s*\(',leaf,re.M):raise ValueError('Mapped PE contains unresolved non-cell dependencies')
 return dict(origin_run=str(origin),netlist_sha256=digest(netlist),source_sha256=digest(project/name),leaf_sha256=hashlib.sha256(leaf.encode()).hexdigest(),wrapper_sha256=hashlib.sha256(wrapper.encode()).hexdigest(),leaf=leaf,wrapper=wrapper)
