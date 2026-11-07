set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/03_io_floorplan.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
set macronames [lsort [dbGet [dbGet top.insts.cell.name RA1SHD_2048x32M8 -p2].name]]
if {[llength $macronames] != 2} {error "Expected two SRAMs"}
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
setAddRingMode -reset
setAddRingMode -avoid_short true -stacked_via_bottom_layer METAL1 -stacked_via_top_layer METAL5
set ring_width 4
set ring_spacing 2
set ring_offset 2
if {[info exists env(CHIP_COMPACT_CORE)] && $env(CHIP_COMPACT_CORE) eq "1"} {set ring_width 2;set ring_spacing 1;set ring_offset 1}
addRing -nets {VDD VSS} -type core_rings -follow core -layer {top METAL5 bottom METAL5 left METAL4 right METAL4} -width $ring_width -spacing $ring_spacing -offset $ring_offset -center 0
# Corner macros use the core rings and over-macro grid directly.
# An extra all-around block ring would collide with the adjacent core ring.
deselectAll
verify_drc -check_only special -report $out/reports/04_rings_drc.rpt
saveDesign $out/checkpoints/04_rings.enc
puts FLOW_STAGE_OK_CHIP_PG_RINGS
setAddStripeMode -reset
setAddStripeMode -break_at {block_ring outer_ring} -allow_jog none -stacked_via_bottom_layer METAL4 -stacked_via_top_layer METAL5 -orthogonal_only false
addStripe -nets {VDD VSS} -layer METAL4 -direction vertical -width 2 -spacing 1 -set_to_set_distance 40 -start_from left -start_offset 8 -block_ring_bottom_layer_limit METAL4 -block_ring_top_layer_limit METAL5 -padcore_ring_bottom_layer_limit METAL4 -padcore_ring_top_layer_limit METAL5
addStripe -nets {VDD VSS} -layer METAL5 -direction horizontal -width 4 -spacing 2 -set_to_set_distance 60 -start_from top -start_offset 1 -block_ring_bottom_layer_limit METAL4 -block_ring_top_layer_limit METAL5 -padcore_ring_bottom_layer_limit METAL4 -padcore_ring_top_layer_limit METAL5
setSrouteMode -blockPinConnectRingPinCorners true
sroute -nets {VDD VSS} -connect {blockPin} -inst $macronames -blockPin useLef -blockPinWidthRange {0.001 1000} -blockPinLayerRange {METAL3 METAL4} -blockPinTarget {ring stripe} -layerChangeRange {METAL3 METAL5} -allowLayerChange 1 -allowJogging 1 -targetViaLayerRange {METAL3 METAL5} -crossoverViaLayerRange {METAL3 METAL5}
foreach name $macronames {
    lassign [lindex [dbGet [dbGet top.insts.name $name -p].box] 0] x0 y0 x1 y1
    setAddStripeMode -reset
    setAddStripeMode -break_at none -allow_jog none -stacked_via_bottom_layer METAL4 -stacked_via_top_layer METAL6 -orthogonal_only false -remove_floating_stripe_over_block false
    addStripe -nets {VDD} -layer METAL6 -direction vertical -width 4 -spacing 4 -set_to_set_distance 40 -start_from left -start_offset 14 -area [list $x0 [expr {$y0-14}] $x1 [expr {$y1+14}]] -block_ring_bottom_layer_limit METAL4 -block_ring_top_layer_limit METAL5 -padcore_ring_bottom_layer_limit METAL4 -padcore_ring_top_layer_limit METAL5
    addStripe -nets {VSS} -layer METAL6 -direction vertical -width 4 -spacing 4 -set_to_set_distance 40 -start_from left -start_offset 22 -area [list $x0 [expr {$y0-20}] $x1 [expr {$y1+20}]] -block_ring_bottom_layer_limit METAL4 -block_ring_top_layer_limit METAL5 -padcore_ring_bottom_layer_limit METAL4 -padcore_ring_top_layer_limit METAL5
    setAddStripeMode -reset
    setAddStripeMode -break_at none -allow_jog none -stacked_via_bottom_layer METAL3 -stacked_via_top_layer METAL6 -orthogonal_only false -split_vias true -remove_floating_stripe_over_block false
    addStripe -nets {VDD VSS} -layer METAL5 -direction horizontal -width 4 -spacing 2 -set_to_set_distance 30 -start_from top -start_offset 15.68 -area [list [expr {$x0-20}] [expr {$y0+10}] [expr {$x1+20}] [expr {$y1-8.85}]] -block_ring_bottom_layer_limit METAL4 -block_ring_top_layer_limit METAL5 -padcore_ring_bottom_layer_limit METAL4 -padcore_ring_top_layer_limit METAL5
}
verify_drc -check_only special -report $out/reports/05_sram_power_drc.rpt
defOut -routing $out/outputs/05_sram_power.def
saveDesign $out/checkpoints/05_sram_power.enc
puts FLOW_STAGE_OK_CHIP_SRAM_POWER
setSrouteMode -reset
setSrouteMode -padPinSplit {10 0.6}
sroute -nets {VDD VSS} -connect {padPin} -area {80 80 1920 1920} -connectInsideArea -padPinTarget {ring} -padPinPortConnect {allPort allGeom} -padPinLayerRange {METAL2 METAL2} -layerChangeRange {METAL2 METAL5} -allowLayerChange 1 -allowJogging 1 -targetViaLayerRange {METAL2 METAL5} -crossoverViaLayerRange {METAL2 METAL5} -detailed_log
sroute -nets {VDD VSS} -connect {corePin} -corePinLayer {METAL1} -corePinTarget {firstAfterRowEnd} -layerChangeRange {METAL1 METAL4} -allowLayerChange 1 -allowJogging 0 -targetViaLayerRange {METAL1 METAL4} -crossoverViaLayerRange {METAL1 METAL4}
addWellTap -cell TAPCELLBWP7T -cellInterval 60 -checkerBoard -prefix WELLTAP
verifyWellTap -cell TAPCELLBWP7T -rule 30 -report $out/reports/06_welltap.rpt
# Dense decap prefill is optional and omitted here to leave legal cell sites.
# Well taps and their rule-30 check remain above.
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
source $run_root/scripts/fix_pg_edge_vias.tcl
verify_drc -check_only special -report $out/reports/06_powerplan_drc.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/06_core_pg.rpt
verifyConnectivity -type special -net {VDDPST VSSPST} -allPGPinPort -error 100000 -report $out/reports/06_io_pg.rpt
defOut -routing $out/outputs/06_powerplan.def
saveDesign $out/checkpoints/06_powerplan.enc
puts FLOW_STAGE_OK_CHIP_POWERPLAN
exit
