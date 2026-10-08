#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/gen_sources.py"
python3 "$root/noc/firmware.py"
mkdir -p "$root/build/noc"
cd "$root/mnist/artifacts"
verilator --binary --timing --top-module tb_noc_mesh -Wno-fatal -j 4 -I. \
 -f "$root/build/sources.f" "$root/tb/tb_noc_mesh.sv" --Mdir "$root/build/obj_noc" > "$root/build/noc/verilator.log" 2>&1
"$root/build/obj_noc/Vtb_noc_mesh" "$@" | tee "$root/build/noc/mesh.log"
