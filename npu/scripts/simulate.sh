#!/usr/bin/env bash
set -euo pipefail
npu_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$npu_root/sw/gen_boot.py"
python3 "$npu_root/scripts/gen_sources.py"
cp "$npu_root/sw/boot.hex" "$npu_root/build/boot.hex"
cd "$npu_root/build"
verilator --binary --timing --top-module tb_npu_soc -Wno-fatal -j 4 \
  -f sources.f "$npu_root/tb/tb_npu_soc.sv" --Mdir obj_dir > verilator_build.log 2>&1
./obj_dir/Vtb_npu_soc | tee simulation.log
verilator --binary --timing --top-module tb_xbar -Wno-fatal -j 4 \
  "$npu_root/rtl/interconnect/xbar.sv" "$npu_root/tb/tb_xbar.sv" --Mdir obj_xbar > verilator_xbar_build.log 2>&1
./obj_xbar/Vtb_xbar | tee xbar_simulation.log
verilator --binary --timing --top-module tb_dma_control -Wno-fatal -j 4 \
  "$npu_root/rtl/npu_dma_channel.sv" "$npu_root/tb/tb_dma_control.sv" --Mdir obj_dma > verilator_dma_build.log 2>&1
./obj_dma/Vtb_dma_control | tee dma_control_simulation.log
