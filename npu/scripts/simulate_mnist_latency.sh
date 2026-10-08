#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/gen_sources.py"
cd "$root/mnist/artifacts"
verilator --binary --timing --top-module tb_mnist_latency -Wno-fatal -j 4 -I. \
 -f "$root/build/sources.f" "$root/tb/tb_mnist_latency.sv" --Mdir "$root/build/obj_mnist_latency" > "$root/build/mnist_latency_build.log" 2>&1
"$root/build/obj_mnist_latency/Vtb_mnist_latency" "$@" | tee "$root/build/mnist_latency.log"
