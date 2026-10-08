#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/gen_sources.py"
cd "$root/mnist/artifacts"
verilator --binary --timing --top-module tb_mnist_stream -Wno-fatal -j 4 -I. \
 -f "$root/build/sources.f" "$root/tb/tb_mnist_stream.sv" --Mdir "$root/build/obj_mnist_stream" > "$root/build/mnist_stream_build.log" 2>&1
"$root/build/obj_mnist_stream/Vtb_mnist_stream" "$@" | tee "$root/build/mnist_stream.log"
