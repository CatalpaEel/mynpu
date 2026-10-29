set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
if {[info exists env(FLOW_RESUME_FINISHED)] && $env(FLOW_RESUME_FINISHED) eq "1"} {
    restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
    deleteFiller -prefix FILLER
} else {
    restoreDesign $out/checkpoints/12_routed.enc.dat mynpu_asic_top
}
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
setNanoRouteMode -drouteFixAntenna true -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
if {[info exists env(FLOW_FIX_ROUTE_SETUP)] && $env(FLOW_FIX_ROUTE_SETUP) eq "1"} {
    # Reserve slack for incremental routing/extraction after cell optimization.
    set setup_margin 0.75
    if {[info exists env(FLOW_SETUP_MARGIN_NS)]} {set setup_margin $env(FLOW_SETUP_MARGIN_NS)}
    if {![string is double -strict $setup_margin] || $setup_margin < 0.0} {error "Invalid setup margin"}
    setOptMode -maxDensity 0.90 -setupTargetSlack $setup_margin -fixHoldAllowSetupTnsDegrade false
    optDesign -postRoute -setup -expandedViews -outDir $out/reports/postRoute_setupFix
}
if {[info exists env(FLOW_FIX_ROUTE_HOLD)] && $env(FLOW_FIX_ROUTE_HOLD) eq "1"} {
    setOptMode -fixHoldAllowSetupTnsDegrade false -holdTargetSlack 0.02
    optDesign -postRoute -hold -expandedViews -outDir $out/reports/postRoute_holdFix
}
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
setFillerMode -core {FILL64BWP7T FILL32BWP7T FILL16BWP7T FILL8BWP7T FILL4BWP7T FILL2BWP7T FILL1BWP7T} -corePrefix FILLER -createRows false -diffCellViol true -ecoMode true -fitGap true -scheme locationFirst -honorPrerouteAsObs false -check_signal_drc true -add_fillers_with_drc false
addFiller
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
checkPlace $out/reports/13_final_place.rpt -ignoreOutOfCore
verify_drc -check_only default -limit 100000 -report $out/reports/13_final_drc.rpt
verifyConnectivity -type regular -error 100000 -report $out/reports/13_final_signal.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/13_final_pg.rpt
verifyProcessAntenna -report $out/reports/13_final_antenna.rpt
timeDesign -postRoute -expandedViews -outDir $out/reports/final_setup
timeDesign -postRoute -hold -expandedViews -outDir $out/reports/final_hold
# Keep mapped synthesis area separate from the implemented cell footprint.
report_area -depth 1 -detail > $out/reports/13_final_logical_area.rpt
report_area -depth 1 -detail -include_physical > $out/reports/13_final_physical_area.rpt
summaryReport -noHtml -outfile $out/reports/13_final_summary.rpt
set diode_report [open $out/reports/13_antenna_diodes.rpt w]
puts $diode_report "antenna_diodes [llength [dbGet -e top.insts.cell.name ANTENNABWP7T]]"
close $diode_report
source $run_root/scripts/report_implemented_area.tcl
report_implemented_area $out/reports
saveDesign $out/checkpoints/13_finished.enc
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
