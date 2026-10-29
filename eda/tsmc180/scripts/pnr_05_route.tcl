set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
if {[file exists $out/checkpoints/11_pre_route.enc.dat]} {
    restoreDesign $out/checkpoints/11_pre_route.enc.dat mynpu_asic_top
} else {
    restoreDesign $out/checkpoints/10_post_cts.enc.dat mynpu_asic_top
}
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
if {![file exists $out/checkpoints/11_pre_route.enc.dat]} {
    saveDesign $out/checkpoints/11_pre_route.enc
}
# Native IO rails are retained; no duplicate ordinary routing across IO OBS.
setAttribute -net VDDPST -skip_routing true
setAttribute -net VSSPST -skip_routing true
setNanoRouteMode -routeWithTimingDriven true -routeDesignRouteClockNetsFirst true
setNanoRouteMode -drouteFixAntenna true -droutePostRouteSpreadWire false
# This library labels its antenna diode as CORE rather than ANTENNACELL,
# so name it explicitly instead of relying on automatic LEF discovery.
setNanoRouteMode -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
# Give congested dataflow nets a bounded search-and-repair attempt rather than
# accepting the router's early stop after its initial detailed-route pass.
setNanoRouteMode -drouteAutoStop false -drouteEndIteration 20
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
routeDesign
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
saveDesign $out/checkpoints/12_route_raw.enc
verify_drc -check_only default -limit 100000 -report $out/reports/12_route_drc.rpt
verifyConnectivity -type regular -error 100000 -report $out/reports/12_route_signal.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/12_route_pg.rpt
verifyProcessAntenna -report $out/reports/12_route_antenna.rpt
timeDesign -postRoute -expandedViews -outDir $out/reports/postRoute
timeDesign -postRoute -hold -expandedViews -outDir $out/reports/postRoute_hold
defOut -routing $out/outputs/12_route.def
saveDesign $out/checkpoints/12_routed.enc
puts FLOW_STAGE_OK_CHIP_ROUTE_COMMANDS_COMPLETED
exit
