# Clean late geometry/antenna errors on the timing-optimized finished layout.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
setAttribute -net VDDPST -skip_routing true
setAttribute -net VSSPST -skip_routing true
setNanoRouteMode -routeWithTimingDriven true -drouteFixAntenna true -droutePostRouteSpreadWire false
setNanoRouteMode -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
setNanoRouteMode -drouteAutoStop false -drouteEndIteration 20
deleteFiller -prefix FILLER
source $run_root/scripts/repair_pg_pin_access.tcl
source $run_root/scripts/repair_antenna_diodes.tcl
repair_reported_pg_pin_access $out/reports/13_final_drc.rpt
for {set pass 0} {$pass < 3} {incr pass} {
    set drc $out/reports/13_repair_drc_$pass.rpt
    set antenna $out/reports/13_repair_antenna_$pass.rpt
    verify_drc -check_only default -limit 100000 -report $drc
    verifyProcessAntenna -report $antenna
    set stream [open $drc r];set drc_text [read $stream];close $stream
    set stream [open $antenna r];set antenna_text [read $stream];close $stream
    set geometry_met [expr {[string first "No DRC violations were found" $drc_text] >= 0}]
    set antenna_met [expr {[string first "No Violations Found" $antenna_text] >= 0}]
    if {$geometry_met && $antenna_met} {break}
    set added 0
    if {!$antenna_met} {set added [repair_reported_antenna $antenna]}
    if {!$geometry_met && $pass > 0} {editDelete -net * -regular_wire_with_drc}
    if {$added > 0 || $pass > 0} {ecoRoute} else {ecoRoute -fix_drc}
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
report_area -depth 1 -detail > $out/reports/13_final_logical_area.rpt
report_area -depth 1 -detail -include_physical > $out/reports/13_final_physical_area.rpt
summaryReport -noHtml -outfile $out/reports/13_final_summary.rpt
set stream [open $out/reports/13_antenna_diodes.rpt w]
puts $stream "antenna_diodes [llength [dbGet -e top.insts.cell.name ANTENNABWP7T]]"
close $stream
source $run_root/scripts/report_implemented_area.tcl
report_implemented_area $out/reports
saveDesign $out/checkpoints/13_finished.enc
puts FLOW_STAGE_OK_CHIP_FINISH_ROUTEFIX_COMMANDS_COMPLETED
exit
