#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/gen_sources.py"
cd "$root/mnist/artifacts"
verilator --binary --timing --top-module tb_mnist -Wno-fatal -j 4 -I. \
 -f "$root/build/sources.f" "$root/tb/tb_mnist.sv" --Mdir "$root/build/obj_mnist" > "$root/build/mnist_verilator_build.log" 2>&1
"$root/build/obj_mnist/Vtb_mnist" "$@" | tee "$root/build/mnist_simulation.log"
