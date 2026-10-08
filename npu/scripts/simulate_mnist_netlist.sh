#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source /home/zzh/vivado/config/env_2025.2.sh
test -f "$root/reports/npu_synth.v"
mkdir -p "$root/build/mnist_gate"
cd "$root/build/mnist_gate"
cp "$root/mnist/artifacts/"*.hex .
cp "$root/mnist/artifacts/test_meta.svh" .
python3 - "$root/reports/npu_synth.v" <<'PY'
import sys
from pathlib import Path
s=Path(sys.argv[1]).read_text();head,body=s.split('`timescale',1)
head='\n'.join(x if x.startswith('//') or not x.strip() else '// '+x for x in head.splitlines())
Path('netlist_for_sim.v').write_text(head+'\n`timescale'+body)
PY
xvlog netlist_for_sim.v "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog.stdout 2>&1
xvlog -sv -i . "$root/tb/tb_mnist.sv" >> xvlog.stdout 2>&1
xelab -debug typical -L unisims_ver -L unimacro_ver -timescale 1ns/1ps -mt 4 tb_mnist glbl -s mnist_gate > xelab.stdout 2>&1
xsim mnist_gate -testplusarg samples=1 -runall -log mnist_gate.log > xsim.stdout 2>&1
cat xsim.stdout
rg -q 'MNIST PASS samples=1' mnist_gate.log
