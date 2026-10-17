#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export PATH="${VCS_BIN:-/opt/eda/Synopsys/vcs/Q-2020.03-SP2-7/bin}:$PATH"
macro="${SRAM_MODEL:-/tmp/mynpu-vcs/RA1SHD_2048x32M8.v}"
for memory in fpga asic; do
  for layout in private shared; do
    python3 -u tools/run_jtag_sim.py --backend vcs --memory "$memory" --layout "$layout" \
      --vectors 64 --boots 3 --macro-model "$macro"
  done
done
