# Core-only physical feasibility, shared TT timing view; no IO pad cells.
# PNR_STAGE selects a restartable stage. Tcl errors terminate the batch job.
proc run_stage {} {
    global init_verilog init_top_cell init_lef_file init_mmmc_file init_pwr_net init_gnd_net
    source [file join [file dirname [info script]] paths.tcl]
    set stage $::env(PNR_STAGE)
    setMultiCpuUsage -localCpu 8
    if {$stage eq "init"} {
        set init_verilog $out/netlist.v
        set init_top_cell npu_asic_top
        set init_lef_file $lefs
        set init_mmmc_file $out/scripts/mmmc.tcl
        set init_pwr_net VDD
        set init_gnd_net VSS
        setLibraryUnit -cap 1pf -time 1ns
        init_design
    } else {
        array set previous {place init pgfix place cts pgfix route cts finish route cleanup finish}
        restoreDesign $out/checkpoints/$previous($stage).enc.dat npu_asic_top
    }
    setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
    setAnalysisMode -analysisType onChipVariation -cppr both
    setDelayCalMode -SIAware false
    setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
    if {$stage eq "init"} {
        floorPlan -site core7T -b {0 0 2000 2000 0 0 2000 2000 20.16 20.16 1979.6 1979.52} -noSnapToGrid
        set macros [lsort [dbGet [dbGet top.insts.cell.name RA1SHD_2048x32M8 -p2].name]]
        if {[llength $macros] != 2} {error "Expected two SRAMs, found $macros"}
        foreach name $macros xy {{100 120} {100 1130}} {
            lassign $xy x y
            placeInstance $name $x $y R0 -fixed
            addHaloToBlock 20 20 20 20 $name -snapToSite
        }
        setPinAssignMode -pinEditInBatch true
        editPin -pin [dbGet top.terms.name] -side LEFT -layer METAL3 -spreadType SIDE -fixedPin
        setPinAssignMode -pinEditInBatch false
        globalNetConnect VDD -type pgpin -pin VDD -all
        globalNetConnect VSS -type pgpin -pin VSS -all
        addRing -nets {VDD VSS} -type core_rings -follow core -layer {top METAL5 bottom METAL5 left METAL4 right METAL4} -width 4 -spacing 2 -offset 2
        foreach name $macros {
            deselectAll
            selectInst $name
            addRing -nets {VDD VSS} -type block_rings -around selected -layer {top METAL5 bottom METAL5 left METAL4 right METAL4} -width 4 -spacing 2 -offset 5
        }
        deselectAll
        setAddStripeMode -break_at {block_ring outer_ring} -stacked_via_bottom_layer METAL4 -stacked_via_top_layer METAL5
        addStripe -nets {VDD VSS} -layer METAL4 -direction vertical -width 2 -spacing 2 -set_to_set_distance 60 -start_offset 25
        addStripe -nets {VDD VSS} -layer METAL5 -direction horizontal -width 4 -spacing 2 -set_to_set_distance 80 -start_offset 25
        sroute -nets {VDD VSS} -connect {blockPin corePin} -blockPin useLef -blockPinWidthRange {0.001 1000} -layerChangeRange {METAL1 METAL6} -allowLayerChange 1 -allowJogging 1
        addWellTap -cell TAPCELLBWP7T -cellInterval 60 -checkerBoard -prefix WELLTAP
        checkFPlan -reportUtil -outFile $out/reports/floorplan.rpt
    } elseif {$stage eq "place"} {
        setPlaceMode -place_global_cong_effort high -place_global_max_density 0.90
        setOptMode -maxDensity 0.92
        place_opt_design
        setTieHiLoMode -cell {TIEHBWP7T TIELBWP7T} -maxFanout 8 -maxDistance 50
        addTieHiLo
        refinePlace
        checkPlace $out/reports/place_check.rpt
        timeDesign -preCTS -expandedViews -outDir $out/reports/preCTS
    } elseif {$stage eq "pgfix"} {
        set macronames [lsort [dbGet [dbGet top.insts.cell.name RA1SHD_2048x32M8 -p2].name]]
        setSrouteMode -blockPinConnectRingPinCorners true
        sroute -nets {VDD VSS} -connect {blockPin} -inst $macronames -blockPin useLef -blockPinWidthRange {0.001 1000} -blockPinLayerRange {METAL3 METAL4} -blockPinTarget {blockring} -layerChangeRange {METAL3 METAL5} -allowLayerChange 1 -allowJogging 1 -targetViaLayerRange {METAL3 METAL5} -crossoverViaLayerRange {METAL3 METAL5}
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

        sroute -nets {VDD VSS} -connect {corePin} -corePinLayer {METAL1} -corePinTarget {firstAfterRowEnd} -layerChangeRange {METAL1 METAL4} -allowLayerChange 1 -allowJogging 0 -targetViaLayerRange {METAL1 METAL4} -crossoverViaLayerRange {METAL1 METAL4}
        source $out/scripts/fix_pg_edge_vias.tcl
    } elseif {$stage eq "cts"} {
        set_ccopt_property primary_delay_corner delay_tt
        set_ccopt_property buffer_cells {CKBD1BWP7T CKBD2BWP7T CKBD4BWP7T CKBD6BWP7T CKBD8BWP7T CKBD10BWP7T CKBD12BWP7T}
        set_ccopt_property inverter_cells {INVD1BWP7T INVD2BWP7T INVD4BWP7T INVD8BWP7T INVD12BWP7T}
        set_ccopt_property update_io_latency false
        set_ccopt_property force_update_io_latency false
        create_ccopt_clock_tree_spec -views {func_tt}
        ccopt_design -check_prerequisites
        ccopt_design
        timeDesign -postCTS -expandedViews -outDir $out/reports/postCTS
        timeDesign -postCTS -hold -expandedViews -outDir $out/reports/postCTS_hold
    } elseif {$stage eq "route"} {
        setNanoRouteMode -routeWithTimingDriven true -routeDesignRouteClockNetsFirst true
        setNanoRouteMode -drouteFixAntenna true -routeInsertAntennaDiode true -routeAntennaCellName ANTENNABWP7T
        setNanoRouteMode -drouteAutoStop false -drouteEndIteration 20
        setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
        routeDesign
        timeDesign -postRoute -expandedViews -outDir $out/reports/postRoute
        timeDesign -postRoute -hold -expandedViews -outDir $out/reports/postRoute_hold
    } elseif {$stage eq "finish"} {
        setOptMode -fixHoldAllowSetupTnsDegrade false -holdTargetSlack 0.02
        optDesign -postRoute
        optDesign -postRoute -hold
        timeDesign -postRoute -expandedViews -outDir $out/reports/final
        timeDesign -postRoute -hold -expandedViews -outDir $out/reports/final_hold
        setFillerMode -core {FILL64BWP7T FILL32BWP7T FILL16BWP7T FILL8BWP7T FILL4BWP7T FILL2BWP7T FILL1BWP7T} -corePrefix FILLER -createRows false -diffCellViol true -ecoMode true -fitGap true -scheme locationFirst -honorPrerouteAsObs false -check_signal_drc true -add_fillers_with_drc false
        addFiller
        checkPlace $out/reports/final_place.rpt
        verifyProcessAntenna -report $out/reports/antenna.rpt
        saveNetlist $out/outputs/routed.v -excludeLeafCell -removePowerGround -excludeCellInst {TAPCELLBWP7T ANTENNABWP7T}
        rcOut -spef $out/outputs/routed.spef
        write_sdf $out/outputs/routed.sdf
    } elseif {$stage eq "cleanup"} {
        # Trim only electrically dangling PG stubs; preserve connected power paths.
        editTrim -nets {VDD VSS}
        globalNetConnect VDD -type pgpin -pin VDD -all
        globalNetConnect VSS -type pgpin -pin VSS -all
        timeDesign -postRoute -expandedViews -outDir $out/reports/clean_setup
        timeDesign -postRoute -hold -expandedViews -outDir $out/reports/clean_hold
        checkPlace $out/reports/clean_place.rpt
        verifyProcessAntenna -report $out/reports/clean_antenna.rpt
        saveNetlist $out/outputs/routed.v -excludeLeafCell -removePowerGround -excludeCellInst {TAPCELLBWP7T ANTENNABWP7T}
        rcOut -spef $out/outputs/routed.spef
        write_sdf $out/outputs/routed.sdf
    } else {error "Unknown PNR_STAGE $stage"}
    globalNetConnect VDD -type pgpin -pin VDD -all
    globalNetConnect VSS -type pgpin -pin VSS -all
    verify_drc -limit 100000 -report $out/reports/${stage}_drc.rpt
    verifyConnectivity -type regular -error 100000 -report $out/reports/${stage}_signal.rpt
    verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/${stage}_pg.rpt
    report_area > $out/reports/${stage}_area.rpt
    set area_file [open $out/reports/${stage}_footprint.rpt w]
    set areas [dict create standard 0.0 sram 0.0 filler 0.0]
    set counts [dict create standard 0 sram 0 filler 0]
    foreach inst [dbGet top.insts] cell [dbGet top.insts.cell] {
        set box [lindex [dbGet $inst.box] 0]
        lassign $box x0 y0 x1 y1
        set group [expr {[dbGet $cell.name] eq "RA1SHD_2048x32M8" ? "sram" : "standard"}]
        if {[regexp {^FILL[0-9]+BWP7T$} [dbGet $cell.name]]} {set group filler}
        dict incr counts $group
        dict set areas $group [expr {[dict get $areas $group]+($x1-$x0)*($y1-$y0)}]
    }
    puts $area_file "die_box [dbGet top.fPlan.box]"
    puts $area_file "core_box [dbGet top.fPlan.coreBox]"
    foreach group {standard sram filler} {
        puts $area_file "${group}_count [dict get $counts $group]"
        puts $area_file "${group}_bbox_area_um2 [dict get $areas $group]"
    }
    close $area_file
    defOut -routing $out/outputs/${stage}.def
    saveDesign $out/checkpoints/${stage}.enc
    puts "PNR_STAGE_PASS $stage"
}
if {[catch {run_stage} message options]} {
    puts stderr "PNR_STAGE_FAILED: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
