# Optional recovery after high-density placement. No clock/RTL/die changes.
# Keep the original 08 checkpoint; CTS can explicitly consume 08_reclaimed.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/08_post_tie.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
# Temporarily permit the reclaim command to start above the usual 99% bound.
# reclaimArea only downsizes/deletes/declones; this does not waive legalization.
setOptMode -maxDensity 0.999 -setupTargetSlack 0
reclaimArea
setOptMode -maxDensity 0.99
refinePlace
checkPlace $out/reports/08_reclaimed_place.rpt -ignoreOutOfCore
set status [open $out/reports/08_reclaimed_status.rpt w]
set unplaced [dbGet -e -p top.insts.pStatus unplaced]
puts $status "unplaced [llength $unplaced]"
close $status
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
timeDesign -preCTS -expandedViews -outDir $out/reports/preCTS_reclaimed
defOut -routing $out/outputs/08_reclaimed.def
saveDesign $out/checkpoints/08_reclaimed.enc
puts FLOW_STAGE_OK_CHIP_RECLAIM_COMMANDS_COMPLETED
exit
