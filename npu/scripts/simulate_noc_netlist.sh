#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source /home/zzh/vivado/config/env_2025.2.sh
mkdir -p "$root/build/noc/gate"
cd "$root/build/noc/gate"
cp "$root/mnist/artifacts/"*.hex .
python3 "$root/noc/gate_adapter.py"
xvlog netlist_for_sim.v "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog.stdout 2>&1
xvlog -sv gate_port_adapter.sv >> xvlog.stdout 2>&1
xvlog -sv -d NOC_GATE_SIM "$root/tb/tb_noc_mesh.sv" >> xvlog.stdout 2>&1
xelab -debug typical -L unisims_ver -L unimacro_ver -timescale 1ns/1ps -mt 4 tb_noc_mesh glbl -s noc_gate > xelab.stdout 2>&1
xsim noc_gate -runall -log noc_gate.log > xsim.stdout 2>&1
cat xsim.stdout
rg -q 'NOC MESH PASS identical_nodes=4' noc_gate.log
