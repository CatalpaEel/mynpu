set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_calibre_fixed.enc.dat mynpu_asic_top
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
# WB rule CB.S.2.M5/M6 requires 2.5um from native bond metal.
# Local rectangles are verified from the original PAD60LU_OBV GDS (um):
# M5=(3.3,0)-(56.7,71.36); M6=(1.5,0)-(58.5,73.16).
# Keepout adds routing constraints only, not fabricated metal or cell changes.
set affected {}
set bonds [dbGet top.insts.cell.name PAD60LU_OBV -p2]
if {[llength $bonds]!=37} {error "Unexpected number of bond PADs"}
set index 0
foreach inst $bonds {
 set orientation [dbGet $inst.orient]
 lassign [lindex [dbGet $inst.box] 0] ix0 iy0 ix1 iy1
 foreach {layer x0 y0 x1 y1} {METAL5 3.3 0.0 56.7 71.36 METAL6 1.5 0.0 58.5 73.16} {
  set xs {};set ys {}
  foreach {x y} [list $x0 $y0 $x0 $y1 $x1 $y0 $x1 $y1] {
   switch $orientation {
    R0 {set xx $x;set yy $y}
    R180 {set xx [expr {60.0-$x}];set yy [expr {73.16-$y}]}
    R90 {set xx [expr {73.16-$y}];set yy $x}
    R270 {set xx $y;set yy [expr {60.0-$x}]}
    default {error "Unexpected bond orientation $orientation"}
   }
   lappend xs [expr {$ix0+$xx}];lappend ys [expr {$iy0+$yy}]
  }
  set xs [lsort -real $xs];set ys [lsort -real $ys]
  set box [list [expr {max(0.0,[lindex $xs 0]-2.5)}] [expr {max(0.0,[lindex $ys 0]-2.5)}] [expr {min(1950.0,[lindex $xs end]+2.5)}] [expr {min(1950.0,[lindex $ys end]+2.5)}]]
  puts "WB_GUARD [dbGet $inst.name] $layer box=$box"
  createRouteBlk -name WB_BOND_GUARD_$index -layer $layer -exceptpgnet -box $box
  incr index
  foreach wire [dbQuery -area $box -objType wire] {
   if {[dbGet $wire.layer.name] eq $layer} {lappend affected [lindex [dbGet $wire.net.name] 0]}
  }
 }
}
set affected [lsort -unique $affected]
puts "WB_GUARD_AFFECTED_NETS count=[llength $affected] $affected"
if {[llength $affected]>64} {error "Review unexpectedly broad WB ECO"}
foreach name $affected {
 set net [dbGetNetByName $name]
 if {$name in {VDD VSS VDDPST VSSPST} || $net eq "0x0"} {error "Unexpected WB ECO net $name"}
 puts "WB_REROUTE $name clock=[dbGet $net.isClock]"
 if {[dbGet $net.isClock]} {error "Review clock impact before rerouting"}
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
saveDesign $out/checkpoints/13_wb_fixed.enc
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
