set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
deleteFiller -prefix FILLER
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
# Repair the two geometry-identical PG overlaps already reported in this run.
set arrays [dbQuery -area {1050 128 1112 131} -objType sViaInst]
set removed 0
set remove_arrays {}
foreach v $arrays {
    if {![string match VIAGEN12_* [dbGet $v.via.name]] || [dbGet $v.net.name] ne "VDD"} {continue}
    lassign [lindex [dbGet $v.pt] 0] vx vy
    if {abs($vy-129.36)>0.001 || (abs($vx-1059.48)>0.001 && abs($vx-1099.48)>0.001)} {continue}
    if {[llength [lindex [dbGet $v.cutRects] 0]] != 19} {error "Unexpected target via cuts"}
    set retained 0
    foreach other $arrays {
        if {$other eq $v || ![string match VIAGEN12_* [dbGet $other.via.name]] || [dbGet $other.net.name] ne "VDD"} {continue}
        if {[llength [lindex [dbGet $other.cutRects] 0]] < 18} {continue}
        lassign [lindex [lindex [dbGet $other.botRects] 0] 0] bx0 by0 bx1 by1
        lassign [lindex [lindex [dbGet $other.topRects] 0] 0] tx0 ty0 tx1 ty1
        if {$bx0 <= $vx-1.0 && $bx1 >= $vx+1.0 && $by0 <= $vy && $by1 >= $vy && $tx0 <= $vx-1.0 && $tx1 >= $vx+1.0 && $ty0 <= $vy && $ty1 >= $vy} {set retained 1;break}
    }
    if {!$retained} {error "No retained same-net M1/M2 array at $vx $vy"}
    puts "RF1R1W_PG_OVERLAP_REMOVE at=$vx,$vy retained=[dbGet $other.via.name]"
    lappend remove_arrays $v
    incr removed
}
deselectAll
if {$removed != 2} {error "Expected exactly two reproduced PG overlaps; got $removed"}
foreach v $remove_arrays {
    deselectAll
    dbSelectObj $v
    editDelete -selected -type Special -object_type Via
}
deselectAll
# A last-row signal pin's access via can conflict with a preserved PG via.
# Reserve only that cell's old site and legally move the cell, preserving PG.
proc repair_reported_pg_pin_access {report} {
    if {![file exists $report]} {return 0}
    set stream [open $report r]
    set records {}
    set net ""
    while {[gets $stream line] >= 0} {
        if {[regexp {Regular Wire of Net (\S+) & (?:Special Wire of Net (VDD|VSS)|Pin of Cell (i_pad_\S+))\s+\( METAL2 \)} $line -> current supply pad]} {
            set net $current
        } elseif {$net ne "" && [regexp {Bounds\s*:\s*\(\s*([0-9.]+),\s*([0-9.]+)\s*\)\s*\(\s*([0-9.]+),\s*([0-9.]+)\s*\)} $line -> x0 y0 x1 y1]} {
            lappend records [list $net [expr {($x0+$x1)/2.0}] [expr {($y0+$y1)/2.0}]]
            set net ""
        }
    }
    close $stream
    set core [lindex [dbGet top.fPlan.coreBox] 0]
    set moved [dict create]
    foreach record $records {
        lassign $record net x y
        if {$y > [lindex $core 1]+2.0 && $y < [lindex $core 3]-2.0} {continue}
        set connection [dbGetNetByName $net]
        if {$connection eq "0x0" || $connection eq ""} {error "PG-access net not found: $net"}
        set nearest ""
        set distance 1.0e30
        foreach terminal [dbGet $connection.instTerms] {
            set instance [lindex [dbGet $terminal.inst] 0]
            if {[dbGet $instance.cell.baseClass] ne "core" || [dbGet $instance.pStatus] ne "placed"} {continue}
            set point [lindex [dbGet $terminal.pt] 0]
            lassign $point px py
            set d [expr {($px-$x)*($px-$x)+($py-$y)*($py-$y)}]
            if {$d < $distance} {set distance $d;set nearest $instance}
        }
        if {$nearest eq "" || $distance > 6.25} {error "No movable cell pin within 2.5um of PG-access DRC on $net"}
        if {[dict exists $moved $nearest]} {continue}
        set box [lindex [dbGet $nearest.box] 0]
        if {abs([lindex $box 1]-[lindex $core 1]) > 0.1 && abs([lindex $box 3]-[lindex $core 3]) > 0.1} {error "PG-access candidate is not in a boundary row"}
        dict set moved $nearest $box
    }
    dict for {instance box} $moved {
        set identifier [llength [dbGet -e top.fPlan.pBlkgs.name]]
        while {[lsearch -exact [dbGet -e top.fPlan.pBlkgs.name] PG_PIN_ACCESS_$identifier] >= 0} {incr identifier}
        createPlaceBlockage -name PG_PIN_ACCESS_$identifier -type hard -box $box -snapToSite
        puts "FLOW_PG_PIN_ACCESS_MOVE [lindex [dbGet $instance.name] 0] old_box=$box"
        dbSet $instance.pStatus unplaced
    }
    if {[dict size $moved] > 0} {
        ecoPlace -fixPlacedInsts true -timing_driven false
        globalNetConnect VDD -type pgpin -pin VDD -all
        globalNetConnect VSS -type pgpin -pin VSS -all
        ecoRoute
    }
    puts "FLOW_PG_PIN_ACCESS_MOVED [dict size $moved]"
    return [dict size $moved]
}

verify_drc -check_only default -limit 100000 -report $out/reports/13_eco_before_move.rpt
repair_reported_pg_pin_access $out/reports/13_eco_before_move.rpt
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
setFillerMode -core {FILL64BWP7T FILL32BWP7T FILL16BWP7T FILL8BWP7T FILL4BWP7T FILL2BWP7T FILL1BWP7T} -corePrefix FILLER -createRows false -diffCellViol true -ecoMode true -fitGap true -scheme locationFirst -honorPrerouteAsObs false -check_signal_drc true -add_fillers_with_drc false
# The library recommends incremental routing after filler insertion.
addFiller
ecoRoute -target
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
editTrim -nets {VDD VSS}
# A top-level port lies on its one native PAD metal terminal. Preserve the
# internal core nets; remove only unnecessary external PAD router excursions.
foreach port {clk_i rst_ni boot_ready_i tck_i tms_i td_i td_o npu_irq_o cpu_debug_halted_o} {
    set net [dbGetNetByName $port]
    if {[llength [dbGet $net.instTerms]] != 1 || [dbGet $net.instTerms.name] ne "i_pad_$port/PAD" || [dbGet $net.terms.name] ne $port} {error "Unexpected external PAD topology $port"}
    set objects [concat [dbGet -e $net.wires] [dbGet -e $net.vias]]
    if {[llength $objects]} {
        deselectAll
        foreach obj $objects {dbSelectObj $obj}
        editDelete -selected -type Regular
    }
}
deselectAll
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
saveDesign $out/checkpoints/13_eco_fixed.enc
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
