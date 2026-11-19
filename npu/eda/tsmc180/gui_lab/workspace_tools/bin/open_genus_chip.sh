#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DISPLAY:-}" ]]; then
  echo "请在服务器远程桌面的图形终端运行（DISPLAY为空）。" >&2
  exit 1
fi
cd "$LAB_ROOT/runs/chip/mynpu/chip_synth"
exec genus -legacy_gui -log launcher "$@"
