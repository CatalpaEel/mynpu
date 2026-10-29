# Supplement the automatic diode pass using the actual antenna report.
# Two small diodes per remaining net provide additional diffusion protection,
# including SRAM inputs that already have one insufficient diode. No logic
# function changes; detailRoute must reconnect and recheck every addition.
proc repair_reported_antenna {report} {
    if {![file exists $report]} {return 0}
    set stream [open $report r]
    set records [dict create]
    set net ""
    while {[gets $stream line] >= 0} {
        if {[regexp {^(\S+) \([0-9]+\)$} $line -> current]} {
            set net $current
        } elseif {$net ne "" && [regexp {^  (\S+)  \((\S+)\) (\S+)$} $line -> sink cell pin]} {
            if {![dict exists $records $net]} {dict set records $net [list $sink $pin]}
        }
    }
    close $stream
    set count 0
    set added 0
    dict for {net endpoint} $records {
        lassign $endpoint sink pin
        set instance [dbGetInstByName $sink]
        if {$instance eq "0x0" || $instance eq ""} {error "Antenna sink not found: $sink"}
        set point ""
        foreach terminal [dbGet $instance.instTerms] {
            if {[lindex [dbGet $terminal.cellTerm.name] 0] eq $pin} {
                set point [dbGet $terminal.pt]
                break
            }
        }
        if {[llength $point] == 1} {set point [lindex $point 0]}
        if {[llength $point] != 2} {error "Antenna sink pin location not found: $sink/$pin"}
        for {set i 0} {$i < 2} {incr i} {
            set name ANTENNA_REPAIR_$count
            while {[dbGetInstByName $name] ne "0x0" && [dbGetInstByName $name] ne ""} {
                incr count
                set name ANTENNA_REPAIR_$count
            }
            # addInst rejects -loc together with an unplaced status. Seed the
            # location first, then let ecoPlace legalize only these new cells.
            addInst -cell ANTENNABWP7T -inst $name -loc $point -place_status placed
            dbSet [dbGetInstByName $name].pStatus unplaced
            attachTerm $name I $net
            incr count
            incr added
        }
    }
    if {$added > 0} {
        globalNetConnect VDD -type pgpin -pin VDD -all
        globalNetConnect VSS -type pgpin -pin VSS -all
        ecoPlace -fixPlacedInsts true -timing_driven false
    }
    puts "FLOW_ANTENNA_SUPPLEMENT_ADDED $added"
    return $added
}
