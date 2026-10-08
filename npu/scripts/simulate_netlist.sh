#!/usr/bin/env bash
set -euo pipefail
npu_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source /home/zzh/vivado/config/env_2025.2.sh
test -f "$npu_root/reports/npu_synth.v"
mkdir -p "$npu_root/build/netlist_sim"
cd "$npu_root/build/netlist_sim"
cp "$npu_root/sw/boot.hex" boot.hex
# Vivado 2025.2 emits a multiline Rocky Linux host string into its header.
# Comment the stray OS release line in a simulation-only copy; HDL is unchanged.
python3 - "$npu_root/reports/npu_synth.v" <<'PYCODE'
import sys
from pathlib import Path
s=Path(sys.argv[1]).read_text()
head,body=s.split('`timescale',1)
head='\n'.join(line if line.startswith('//') or not line.strip() else '// '+line for line in head.splitlines())
Path('netlist_for_sim.v').write_text(head+'\n`timescale'+body)
PYCODE
xvlog netlist_for_sim.v "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog.stdout 2>&1
xvlog -sv -d NETLIST "$npu_root/tb/tb_npu_soc.sv" >> xvlog.stdout 2>&1
xelab -L unisims_ver -L unimacro_ver -timescale 1ns/1ps -mt 4 \
  tb_npu_soc glbl -s npu_gate > xelab.stdout 2>&1
xsim npu_gate -runall -log netlist_simulation.log > xsim.stdout 2>&1
cat xsim.stdout
if ! rg -q 'ALL PASS' netlist_simulation.log; then
  echo "Netlist simulation did not pass" >&2
  exit 1
fi
