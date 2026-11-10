set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_eco_fixed.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
setNanoRouteMode -drouteFixAntenna true -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
set opt_max_density 0.99
if {[info exists env(FLOW_OPT_MAX_DENSITY)]} {set opt_max_density $env(FLOW_OPT_MAX_DENSITY)}
if {![string is double -strict $opt_max_density] || $opt_max_density <= 0 || $opt_max_density >= 1} {error "Invalid optimization density bound"}
setOptMode -maxDensity $opt_max_density
# Calibre M2.S.2 at (904.7..905.5,115.0..115.45): a CPU internal
# route-to-via enclosure is <0.6um from the native IO wide-M2 rail.
# Keep all cells and PG. Reroute only this net above M2 (pin-access vias remain).
# The native PVSS2CDG top edge is wide M2 at y=115um. Keep
# signal M2 (including via enclosures) at least 0.6um away; the old
# LEF routing abstract did not encode this native wide-metal spacing.
createRouteBlk -name CALIBRE_M2_PAD_SPACING -layer METAL2 -exceptpgnet -box {849.0 114.8 911.0 115.8}
set target i_soc/i_core_i_cpu/core_i_ex_stage_i_csa_tree_mult_i_add_228_5_groupi_n_220
set affected [list $target]
foreach obj [dbQuery -area {849.0 114.8 911.0 115.8} -objType wire] {
 if {[dbGet $obj.layer.name] eq "METAL2"} {lappend affected [dbGet $obj.net.name]}
}
set affected [lsort -unique $affected]
puts "CALIBRE_M2_AFFECTED_NETS $affected"
if {[llength $affected]>3} {error "Review expanded Calibre ECO scope"}
foreach name $affected {
 set net [dbGetNetByName $name]
 if {$net eq "0x0" || [llength [dbGet $net.instTerms]]<2 || $name in {VDD VSS VDDPST VSSPST}} {error "Unexpected ECO topology $name"}
 set objects [concat [dbGet -e $net.wires] [dbGet -e $net.vias]]
 deselectAll
 foreach obj $objects {dbSelectObj $obj}
 editDelete -selected -type Regular
}
deselectAll
setNanoRouteMode -routeBottomRoutingLayer 2 -routeTopRoutingLayer 6
ecoRoute
# Preserve physical top-port/native-PAD overlap; no internal nets are deleted.
foreach port {clk_i rst_ni boot_ready_i tck_i tms_i td_i td_o npu_irq_o cpu_debug_halted_o} {
 set n [dbGetNetByName $port]
 if {[llength [dbGet $n.instTerms]]!=1 || [dbGet $n.instTerms.name] ne "i_pad_$port/PAD" || [dbGet $n.terms.name] ne $port} {error "Unexpected PAD topology"}
 set objects [concat [dbGet -e $n.wires] [dbGet -e $n.vias]]
 if {[llength $objects]} {deselectAll;foreach obj $objects {dbSelectObj $obj};editDelete -selected -type Regular}
}
deselectAll
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
saveDesign $out/checkpoints/13_calibre_fixed.enc
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
