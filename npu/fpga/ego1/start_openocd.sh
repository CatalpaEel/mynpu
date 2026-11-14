#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
# Start a server only. jtag_validation.py performs reset/load/start explicitly.
exec openocd -f npu/fpga/ego1/ft232h.cfg -f npu/debug/target.cfg \
  -c 'bindto 127.0.0.1' -c 'tcl_port 6666' -c 'telnet_port 4444' -c init "$@"
