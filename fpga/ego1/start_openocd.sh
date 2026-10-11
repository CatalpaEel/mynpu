#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$repo_root/fpga/ego1/ego1_openocd.cfg"

if [[ ! -f "$config" ]]; then
  echo "OpenOCD config not found: $config" >&2
  exit 1
fi

exec openocd -f "$config" "$@"
