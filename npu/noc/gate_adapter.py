"""Wire-only adapter for Vivado's flattened packed-array netlist ports."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
s=(root/'reports/noc/node_synth.v').read_text();head,body=s.split('`timescale',1)
head='\n'.join(x if x.startswith('//') or not x.strip() else '// '+x for x in head.splitlines())
block=re.search(r'module npu_noc_soc\b[\s\S]*?endmodule',body).group(0)
ports=re.findall(r'^\s*(?:input|output)\s+(?:\[[^\]]+\]\s*)?(\\\S+|[a-zA-Z_]\w*)\s*;',block,re.M)
assert len(ports)>80 and len(ports)==len(set(ports))
renamed=re.sub(r'\bmodule npu_noc_soc\b','module noc_node_netlist',body,count=1)
Path('netlist_for_sim.v').write_text(head+'\n`timescale'+renamed)
rtl_head=(root/'rtl/npu_noc_soc.sv').read_text().split(');\n',1)[0]+');\n'
connections=[]
for port in ports:
 expression=port.lstrip('\\')
 connections.append('  .'+port+' ('+expression+')')
Path('gate_port_adapter.sv').write_text(rtl_head+' noc_node_netlist i_netlist(\n'+',\n'.join(connections)+');\n initial if(ROUTER_DEPTH!=2 || MAX_WORDS!=16)$fatal(1,"Netlist has fixed default parameters");\nendmodule\n')
