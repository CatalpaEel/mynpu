#!/usr/bin/env bash
# Board build replaces the historical OOC-only entry; optional Vivado env setup.
set -euo pipefail
npu_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
if [[ -n "${VIVADO_SETTINGS:-}" ]]; then
  source "$VIVADO_SETTINGS"
fi
exec "${PYTHON:-python3}" "$npu_root/fpga/ego1/build.py" "$@"
