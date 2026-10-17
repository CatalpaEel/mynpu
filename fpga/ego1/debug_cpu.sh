#!/usr/bin/env bash
set -euo pipefail
layout="${1:-private}"
if [[ "$layout" != private && "$layout" != shared ]]; then echo 'Usage: debug_cpu.sh private|shared' >&2; exit 1; fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$repo_root/tools/jtag_host.py" --layout "$layout" --prepare-gdb
elf="$repo_root/build/jtag/$layout/firmware.elf"
symbols=()
if [[ -f "$elf" ]]; then symbols=("$elf"); fi
exec gdb-multiarch "${symbols[@]}" -x "$repo_root/build/jtag/$layout/load.gdb"
