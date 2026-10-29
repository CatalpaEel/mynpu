#!/usr/bin/env bash
# One stage per invocation; inspect its reports before starting the next stage.
set -e
if [ "$#" -ne 2 ]; then
    printf 'Usage: bash %s RUN_DIR {grid|pe|tile|synth|chip|01|02|03|04|04b|05|05b|06|06b|07|audit}\n' "$0" >&2
    exit 2
fi
eda_run_dir=$(cd "$1" && pwd)
eda_stage=$2
eda_frozen_runner="$eda_run_dir/scripts/frozen_run_stage.sh"
if [ -f "$eda_frozen_runner" ] && [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$eda_frozen_runner" ]; then
    exec bash "$eda_frozen_runner" "$@"
fi
source /etc/profile.d/eda.sh
case "$eda_stage" in
    grid) eda_work_dir="$eda_run_dir/mynpu/chip_synth"; eda_script=synth_current_grid.tcl; eda_tool=genus; eda_log=launcher.log ;;
    pe) eda_work_dir="$eda_run_dir/mynpu/torus_pe_synth"; eda_script=synth_torus_pe.tcl; eda_tool=genus; eda_log=launcher.log ;;
    tile) eda_work_dir="$eda_run_dir/mynpu/tile_synth"; eda_script=synth_tile_area.tcl; eda_tool=genus; eda_log=launcher.log ;;
    synth) eda_work_dir="$eda_run_dir/mynpu/synth"; eda_script=synth_mynpu.tcl; eda_tool=genus; eda_log=launcher.log ;;
    chip) eda_work_dir="$eda_run_dir/mynpu/chip_synth"; eda_script=synth_chip.tcl; eda_tool=genus; eda_log=launcher.log ;;
    01) eda_script=pnr_01_floorplan_io.tcl ;;
    02) eda_script=pnr_02_powerplan.tcl ;;
    03) eda_script=pnr_03_place.tcl ;;
    04) eda_script=pnr_04_cts.tcl ;;
    04b) eda_script=pnr_04b_holdfix.tcl ;;
    05) eda_script=pnr_05_route.tcl ;;
    05b) eda_script=pnr_05b_routefix.tcl ;;
    06) eda_script=pnr_06_finish.tcl ;;
    06b) eda_script=pnr_06b_routefix.tcl ;;
    07) eda_script=pnr_07_export.tcl ;;
    audit)
        /usr/bin/python3 "$eda_run_dir/scripts/audit_io.py"
        /usr/bin/python3 "$eda_run_dir/scripts/verify_exports.py"
        exit ;;
    *) printf 'Unknown stage: %s\n' "$eda_stage" >&2; exit 2 ;;
esac
if [ "${eda_tool-}" != genus ]; then
    eda_work_dir="$eda_run_dir/mynpu/pnr"
    eda_tool=innovus
    eda_log="${eda_stage}_launcher.log"
fi
cd "$eda_work_dir"
if [ -e "$eda_log" ]; then
    printf 'Refusing to overwrite %s/%s; preserve the earlier attempt before retrying.\n' "$eda_work_dir" "$eda_log" >&2
    exit 2
fi
printf 'Stage %s; log: %s/%s\n' "$eda_stage" "$eda_work_dir" "$eda_log"
if [ "$eda_tool" = genus ]; then
    genus -no_gui -batch -abort_on_error -disable_user_startup \
        -files "$eda_run_dir/scripts/$eda_script" > "$eda_log" 2>&1
else
    FLOW_STAGE_SCRIPT="$eda_run_dir/scripts/$eda_script" \
        innovus -no_gui -files "$eda_run_dir/scripts/batch_stage.tcl" > "$eda_log" 2>&1
fi
printf 'Tool exited; inspect the log and stage reports before continuing.\n'
