# A last-row signal pin's access via can conflict with a preserved PG via.
# Reserve only that cell's old site and legally move the cell, preserving PG.
proc repair_reported_pg_pin_access {report} {
    if {![file exists $report]} {return 0}
    set stream [open $report r]
    set records {}
    set net ""
    while {[gets $stream line] >= 0} {
        if {[regexp {Regular Wire of Net (\S+) & Special Wire of Net (VDD|VSS)\s+\( METAL2 \)} $line -> current supply]} {
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
        if {$y < [lindex $core 3]-2.0} {continue}
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
        if {[lindex $box 3] < [lindex $core 3]-0.1} {error "PG-access candidate is not in the last row"}
        set identifier [llength [dbGet -e top.fPlan.pBlkgs.name]]
        while {[lsearch -exact [dbGet -e top.fPlan.pBlkgs.name] PG_PIN_ACCESS_$identifier] >= 0} {incr identifier}
        createPlaceBlockage -name PG_PIN_ACCESS_$identifier -type hard -box $box -snapToSite
        puts "FLOW_PG_PIN_ACCESS_MOVE [lindex [dbGet $nearest.name] 0] old_box=$box"
        dbSet $nearest.pStatus unplaced
        dict set moved $nearest $box
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
