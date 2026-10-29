# Resume search-and-repair after preserving the initial route reports/database.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/12_routed.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setAttribute -net VDDPST -skip_routing true
setAttribute -net VSSPST -skip_routing true
setNanoRouteMode -routeWithTimingDriven true -drouteSearchAndRepair true
# The default auto-stop can return after the initial pass on a congested design.
# Keep a finite repair budget; this is not a waiver of any DRC or antenna rule.
setNanoRouteMode -drouteAutoStop false -drouteEndIteration 20
setNanoRouteMode -drouteFixAntenna true -droutePostRouteSpreadWire false
setNanoRouteMode -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
source $run_root/scripts/repair_pg_pin_access.tcl
repair_reported_pg_pin_access $out/reports/12_route_drc.rpt
source $run_root/scripts/repair_antenna_diodes.tcl
repair_reported_antenna $out/reports/12_route_antenna.rpt
detailRoute
# Antenna insertion can leave a few late geometry errors after the main SAR
# pass. Populate independent DRC markers, then use the focused ECO repair.
verify_drc -check_only default -limit 100000 -report $out/reports/12_before_eco_drc.rpt
set drc_stream [open $out/reports/12_before_eco_drc.rpt r]
set before_eco [read $drc_stream]
close $drc_stream
if {[string first "No DRC violations were found" $before_eco] < 0} {
    ecoRoute -fix_drc
}
# If local adjustments cannot untangle a collision, rip up only regular signal
# wire segments carrying independently checked DRC markers and reconnect them.
# Keep the PG grid, logical nets, cells and placement intact.
for {set pass 0} {$pass < 2} {incr pass} {
    verify_drc -check_only default -limit 100000 -report $out/reports/12_before_ripup_$pass.rpt
    set drc_stream [open $out/reports/12_before_ripup_$pass.rpt r]
    set remaining [read $drc_stream]
    close $drc_stream
    if {[string first "No DRC violations were found" $remaining] >= 0} {break}
    editDelete -net * -regular_wire_with_drc
    ecoRoute
}
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
saveDesign $out/checkpoints/12_route_repaired.enc
verify_drc -check_only default -limit 100000 -report $out/reports/12_route_drc.rpt
verifyConnectivity -type regular -error 100000 -report $out/reports/12_route_signal.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/12_route_pg.rpt
verifyProcessAntenna -report $out/reports/12_route_antenna.rpt
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
timeDesign -postRoute -expandedViews -outDir $out/reports/postRoute
timeDesign -postRoute -hold -expandedViews -outDir $out/reports/postRoute_hold
defOut -routing $out/outputs/12_route.def
saveDesign $out/checkpoints/12_routed.enc
puts FLOW_STAGE_OK_CHIP_ROUTEFIX_COMMANDS_COMPLETED
exit
