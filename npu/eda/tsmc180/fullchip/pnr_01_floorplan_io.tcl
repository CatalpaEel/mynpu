# Adapted to the current mynpu design from the Lab 4 procedure.
# Fixed 1950um die; nine signal pads; two SRAM macros; single TT analysis.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
file mkdir $out/checkpoints $out/reports $out/outputs
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
setMultiCpuUsage -localCpu 8
set init_verilog $run_root/mynpu/chip_synth/mynpu_asic_top.postsyn.v
set init_top_cell mynpu_asic_top
set init_lef_file [list $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef $pdk/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/tpd018nv_6lm.lef $pdk/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/antenna_6lm.lef $pdk/tpb018v_180a/TSMCHOME/digital/Back_End/lef/tpb018v_180a/cup/6lm/lef/tpb018v_6lm.lef $macro/RA1SHD_2048x32M8.vclef $macro/RA1SHD_2048x32M8_ant.lef]
set init_mmmc_file $run_root/scripts/chip_mmmc.tcl
set init_pwr_net VDD
set init_gnd_net VSS
setLibraryUnit -cap 1pf -time 1ns
init_design
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setDelayCalMode -SIAware false
puts FLOW_STAGE_OK_CHIP_IMPORT
# Default to the reference 130um-margin floorplan. Compact ring is an experiment.
set core_box {130.48 129.36 1819.84 1819.84}
if {[info exists env(CHIP_COMPACT_CORE)] && $env(CHIP_COMPACT_CORE) eq "1"} {set core_box {122.08 121.52 1827.68 1827.68}}
floorPlan -site core7T -b [concat {0 0 1950 1950 0 0 1950 1950} $core_box] -noSnapToGrid
lassign $core_box lx by rx ty
set macronames [lsort [dbGet [dbGet top.insts.cell.name RA1SHD_2048x32M8 -p2].name]]
if {[llength $macronames] != 2} {error "Expected two SRAM macros; got $macronames"}
# Respect the full macro outline: native OVERLAP is inset by 5.2um.
# 12um at the signal edge leaves about 6.8um outside the outline; other
# halos of 5.2um reserve the outline without wasting an extra outer channel.
set macro_plan [list [list [lindex $macronames 0] $lx $by R180 5.2 5.2 5.2 12] [list [lindex $macronames 1] $lx [expr {$ty-723.85}] R0 5.2 12 5.2 5.2]]
if {[info exists env(CHIP_MACRO_PLAN)] && $env(CHIP_MACRO_PLAN) eq "diagonal"} {
    set macro_plan [list [list [lindex $macronames 0] $lx $by R90 5.2 5.2 12 5.2] [list [lindex $macronames 1] [expr {$rx-723.85}] [expr {$ty-554.595}] R270 12 5.2 5.2 5.2]]
}
foreach row $macro_plan {
    lassign $row name x y orientation left bottom right top
    placeInstance $name $x $y $orientation -fixed
    addHaloToBlock $left $bottom $right $top $name -snapToSite
}
# Remove rows against the full macro outline, not the inset OVERLAP.
# Leave 0.50um M1 clearance; do not block legal macro signal pin access.
foreach name $macronames {
 set box [lindex [dbGet [dbGet top.insts.name $name -p].box] 0]
 lassign $box mx0 my0 mx1 my1
 cutRow -area [list [expr {$mx0-0.50}] [expr {$my0-0.50}] [expr {$mx1+0.50}] [expr {$my1+0.50}]]
}
set geometry [open $out/reports/floorplan_geometry.rpt w]
puts $geometry "die [dbGet top.fPlan.box]"
puts $geometry "core [dbGet top.fPlan.coreBox]"
foreach name $macronames {
    set ip [dbGet top.insts.name $name -p]
    puts $geometry "$name box=[dbGet $ip.box] halo=[dbGet $ip.pHaloBox]"
}
close $geometry
checkFPlan -reportUtil -outFile $out/reports/floorplan_check.rpt
saveDesign $out/checkpoints/01_core_floorplan.enc
puts FLOW_STAGE_OK_CHIP_FLOORPLAN
foreach {name x y ori} {corner_bl 0 0 R0 corner_br 1835 0 MY corner_tl 0 1835 MX corner_tr 1835 1835 R180} {
    addInst -cell PCORNER -inst $name -loc [list $x $y] -ori $ori -place_status fixed -dontSnapToPlacementGrid
}
# port, side, tangential coordinate, direction
set signal_plan {
    clk_i top 1600 in rst_ni left 1600 in tck_i left 850 in tms_i left 950 in td_i left 1050 in td_o left 1150 out boot_ready_i bottom 460 in npu_irq_o bottom 1600 out cpu_debug_halted_o right 460 out
}
array set side_ori {top R180 bottom R0 left R270 right R90}
set pad_plan {}
foreach {port side pos direction} $signal_plan {
    if {$side in {top bottom}} {
        set x $pos; set y [expr {$side eq "top" ? 1835 : 0}]
    } else {
        set x [expr {$side eq "right" ? 1835 : 0}]; set y $pos
    }
    set name i_pad_$port
    addInst -cell PDDW0204CDG -inst $name -loc [list $x $y] -ori $side_ori($side) -place_status fixed -dontSnapToPlacementGrid
    # Preserve the core net through a hierarchical terminal while port aliases
    # are normalized by detachModulePort/attachModulePort.
    set core_term [dbGet top.hInst.hInsts.hInstTerms.name i_soc/$port -p]
    if {$core_term eq "0x0" || $core_term eq ""} {
        set original_net [dbGet [dbGet top.terms.name $port -p].net]
        set core_term [lindex [dbGet $original_net.instTerms] 0]
    }
    if {$core_term eq "0x0" || $core_term eq ""} {error "Missing core connection for $port"}
    addNet ${port}_pad
    detachModulePort - $port
    attachModulePort - $port ${port}_pad
    set core_net [dbGet $core_term.net.name]
    set ext_net [dbGet [dbGet top.terms.name $port -p].net.name]
    if {$core_net eq $ext_net || $core_net eq "0x0" || $core_net eq ""} {error "Invalid pad connection $port"}
    attachTerm $name PAD $ext_net
    if {$direction eq "in"} {
        attachTerm $name C $core_net
        attachTerm $name OEN 1'b1
        attachTerm $name IE 1'b1
        attachTerm $name I 1'b0
    } else {
        attachTerm $name I $core_net
        attachTerm $name OEN 1'b0
        attachTerm $name IE 1'b0
    }
    attachTerm $name PE 1'b0
    attachTerm $name DS 1'b0
    lappend pad_plan [list $name PDDW0204CDG $side $pos]
}
set supply_terms {}
foreach side {top bottom left right} {
    foreach {suffix cell pos} {vdd_1 PVDD1CDG 260 vss_1 PVSS1CDG 360 vdd_2 PVDD1CDG 650 vss_2 PVSS1CDG 750 vddio PVDD2CDG 1250 vssio PVSS2CDG 1350 poc PVDD2POC 1450} {
        if {$side in {top bottom}} {
            set x $pos; set y [expr {$side eq "top" ? 1835 : 0}]
        } else {
            set x [expr {$side eq "right" ? 1835 : 0}]; set y $pos
        }
        set name i_pad_${side}_$suffix
        addInst -cell $cell -inst $name -loc [list $x $y] -ori $side_ori($side) -place_status fixed -dontSnapToPlacementGrid
        lappend pad_plan [list $name $cell $side $pos]
        if {$suffix in {vddio poc}} {lappend supply_terms [list $name VDDPST]}
        if {$suffix eq "vssio"} {lappend supply_terms [list $name VSSPST]}
    }
}
# Register actual IO sides before filling. Preserve all fixed geometry.
set io_file [open $out/outputs/io_registration.io w]
puts $io_file "(globals\n version = 3\n io_order = default\n)\n(iopad"
foreach {side corner ori} {topright corner_tr R180 topleft corner_tl MX bottomleft corner_bl R0 bottomright corner_br MY} {
    puts $io_file [format { (%s (inst name="%s" cell="PCORNER" orientation=%s place_status=fixed))} $side $corner $ori]
}
set before [dict create]
foreach row $pad_plan {
    set ip [dbGet top.insts.name [lindex $row 0] -p]
    dict set before [lindex $row 0] [list [dbGet $ip.box] [dbGet $ip.orient]]
}
foreach side {top bottom left right} {
    puts $io_file " ($side"
    foreach row [lsort -real -index 3 $pad_plan] {
        lassign $row name cell row_side pos
        if {$row_side ne $side} {continue}
        puts $io_file [format {  (inst name="%s" cell="%s" offset=%.6f indent=0 orientation=%s place_status=fixed)} $name $cell $pos $side_ori($side)]
    }
    puts $io_file " )"
}
puts $io_file ")"
close $io_file
saveDesign $out/checkpoints/02_pre_io_registration.enc
loadIoFile $out/outputs/io_registration.io -noAdjustDieSize -specifiedIosOnly
dict for {name prior} $before {
    set ip [dbGet top.insts.name $name -p]
    if {[dbGet $ip.box] ne [lindex $prior 0] || [dbGet $ip.orient] ne [lindex $prior 1]} {error "IO registration moved $name"}
}
foreach row $pad_plan {
    lassign $row name cell side pos
    if {$side in {top bottom}} {
        set x $pos; set y [expr {$side eq "top" ? 1876.84 : 0}]
    } else {
        set x [expr {$side eq "right" ? 1876.84 : 0}]; set y $pos
    }
    addInst -physical -cell PAD60LU_OBV -inst bond_$name -loc [list $x $y] -ori $side_ori($side) -place_status fixed -dontSnapToPlacementGrid
}
addNet VDDPST -power
addNet VSSPST -ground
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
foreach row $supply_terms {lassign $row name pin; attachTerm $name $pin $pin}
set ex [open $out/outputs/tie_supply_exclude.txt w]
foreach row $supply_terms {lassign $row name pin; puts $ex $name/$pin}
close $ex
foreach side {top bottom left right} {
    addIoFiller -cell {PFILLER20 PFILLER10 PFILLER5 PFILLER1 PFILLER05 PFILLER0005} -prefix IOF_$side -side $side -fillerOrient $side_ori($side)
}
# External signal labels are placed inside the corresponding bond windows.
foreach {port side pos direction} $signal_plan {
    if {$side in {top bottom}} {
        set x [expr {$pos+10}]; set y [expr {$side eq "top" ? 1948 : 1}]
    } else {
        set x [expr {$side eq "right" ? 1948 : 1}]; set y [expr {$pos+10}]
    }
    set net [dbGet [dbGet top.terms.name $port -p].net.name]
    createPhysicalPin $port -net $net -layer METAL4 -rect [list $x $y [expr {$x+1}] [expr {$y+1}]]
}
createPGPin VDD -net VDD -geom METAL4 270 1948 280 1949
createPGPin VSS -net VSS -geom METAL4 370 1948 380 1949
createPGPin VDDPST -net VDDPST -geom METAL4 1260 1948 1270 1949
createPGPin VSSPST -net VSSPST -geom METAL4 1360 1948 1370 1949
saveNetlist $out/outputs/03_io_connected.v -phys
defOut $out/outputs/03_io_floorplan.def
saveIoFile -locations -includeCellName $out/outputs/io_registered.io
saveDesign $out/checkpoints/03_io_floorplan.enc
puts FLOW_STAGE_OK_CHIP_IO_FLOORPLAN
exit
