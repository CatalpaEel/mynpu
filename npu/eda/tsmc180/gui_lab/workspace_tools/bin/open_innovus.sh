#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DISPLAY:-}" ]]; then
  echo "请在服务器远程桌面的图形终端运行（DISPLAY为空）。" >&2
  exit 1
fi
cd "$LAB_ROOT/runs/chip"
export CHIP_MACRO_PLAN=left CHIP_COMPACT_CORE=0
export FLOW_FIX_ROUTE_SETUP=1 FLOW_FIX_ROUTE_HOLD=1
export FLOW_SETUP_MARGIN_NS=0.30 FLOW_OPT_MAX_DENSITY=0.99
exec innovus "$@"
