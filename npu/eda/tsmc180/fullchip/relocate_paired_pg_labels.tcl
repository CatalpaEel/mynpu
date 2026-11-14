# Frozen trial stage after 13_finished: relocate top PG labels, repair routes,
# then remeasure. This script is specific to jtag_left_paired.json geometry.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
foreach {net x} {VDD 270 VSS 370 VDDPST 1260 VSSPST 1360} {
    deletePGPin -net $net -pg_port
    createPGPin $net -net $net -geom METAL4 $x 1948 [expr {$x+10}] 1949
}
verify_drc -check_only default -limit 100000 -report $out/reports/13_paired_labels_before_route.rpt
setNanoRouteMode -drouteFixAntenna true -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
ecoRoute -target
editTrim -nets {VDD VSS}
checkPlace $out/reports/13_paired_labels_place.rpt -ignoreOutOfCore
verifyConnectivity -type regular -error 100000 -report $out/reports/13_paired_labels_signal.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/13_paired_labels_pg.rpt
verifyConnectivity -type special -net {VDDPST VSSPST} -allPGPinPort -error 100000 -report $out/reports/13_paired_labels_io_pg.rpt
verify_drc -check_only default -limit 100000 -report $out/reports/13_paired_labels_drc.rpt
verifyProcessAntenna -report $out/reports/13_paired_labels_antenna.rpt
timeDesign -postRoute -expandedViews -outDir $out/reports/paired_final_setup
timeDesign -postRoute -hold -expandedViews -outDir $out/reports/paired_final_hold
source $run_root/scripts/report_implemented_area.tcl
report_implemented_area $out/reports
saveDesign $out/checkpoints/13_paired_labels.enc
defOut -routing $out/outputs/13_paired_labels.def
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
