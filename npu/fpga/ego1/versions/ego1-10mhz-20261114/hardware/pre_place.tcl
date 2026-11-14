# Permit the placer to test physical optimization beyond the LUT estimate.
# post_place.tcl restores default resource checks before routing can start.
set_param drc.disableLUTOverUtilError 1
