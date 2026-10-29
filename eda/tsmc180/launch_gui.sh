#!/usr/bin/env bash
set -e
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'Usage: bash %s RUN_DIR [init|CHECKPOINT_BASENAME]\n' "$0" >&2
    exit 2
fi
export EDA_GUI_RUN_DIR=$(cd "$1" && pwd)
export EDA_GUI_CHECKPOINT=${2:-14_exported}
if [ -z "${DISPLAY-}" ]; then
    printf 'DISPLAY is unset. Open a terminal inside the server graphical desktop or use configured X forwarding.\n' >&2
    exit 2
fi
source /etc/profile.d/eda.sh
mkdir -p "$EDA_GUI_RUN_DIR/gui"
cd "$EDA_GUI_RUN_DIR/gui"
innovus -files "$EDA_GUI_RUN_DIR/scripts/gui_open.tcl"
