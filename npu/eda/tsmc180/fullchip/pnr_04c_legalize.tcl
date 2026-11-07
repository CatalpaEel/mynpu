set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/10_post_cts.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
refinePlace
checkPlace $out/reports/11_legalized_place.rpt -ignoreOutOfCore
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
# Do not promote a command marker to a legal checkpoint when refinePlace fails.
set fh [open $out/reports/11_legalized_place.rpt r]
set placement_report [read $fh]
close $fh
if {[regexp {Total instances with placement violations: [1-9]} $placement_report] || ![regexp {Number of Unplaced Instances = 0} $placement_report]} {
    error "CTS placement is not legal; stop before routing"
}
saveDesign $out/checkpoints/11_pre_route.enc
puts FLOW_STAGE_OK_CHIP_CTS_LEGALIZED_COMMANDS_COMPLETED
exit
