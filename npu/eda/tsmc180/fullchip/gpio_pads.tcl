# Native GPIO PADs are instantiated by chip_top.sv, not synthesized from logic.
# Return an empty plan for a historical nine-signal shell.
proc gpio_pad_plan {} {
    set result {}
    set pads [dbGet -e top.insts.name i_pad_gpio*]
    if {[llength $pads] == 0} {return $result}
    if {[llength $pads] != 8} {error "Expected exactly eight native GPIO PADs: $pads"}
    foreach {bit side pos} {0 right 850 1 right 950 2 right 1050 3 right 1150 4 bottom 850 5 bottom 950 6 bottom 1050 7 bottom 1150} {
        set name i_pad_gpio$bit
        set cell [dbGet [dbGet top.insts.name $name -p].cell.name]
        if {$cell ne "PDDW0204CDG"} {error "Wrong GPIO PAD cell $name: $cell"}
        lappend result [list $name $cell $side $pos]
    }
    return $result
}
proc place_gpio_pads {} {
    lassign [lindex [dbGet top.fPlan.box] 0] x0 y0 x1 y1
    foreach row [gpio_pad_plan] {
        lassign $row name cell side pos
        if {$side eq "right"} {placeInstance $name [expr {$x1-115}] $pos R90 -fixed}
        if {$side eq "bottom"} {placeInstance $name $pos 0 R0 -fixed}
    }
}
proc label_gpio_pads {} {
    lassign [lindex [dbGet top.fPlan.box] 0] x0 y0 x1 y1
    foreach row [gpio_pad_plan] {
        lassign $row name cell side pos
        if {![regexp {gpio([0-7])$} $name -> bit]} {error "GPIO instance name: $name"}
        set port [format {gpio_io[%d]} $bit]
        set term "0x0"
        foreach candidate [dbGet top.terms] {
            if {[lindex [dbGet $candidate.name] 0] eq $port} {set term $candidate; break}
        }
        if {$term eq "0x0"} {error "Missing bidirectional GPIO port $port"}
        set net [lindex [dbGet $term.net.name] 0]
        set x [expr {$side eq "right" ? $x1-2 : $pos+10}]
        set y [expr {$side eq "right" ? $pos+10 : 1}]
        editPin -pin $port -layer METAL4 -assign [list $x $y] -side INSIDE -snap MGRID -fixOverlap 0 -pinWidth 1 -pinDepth 1 -fixedPin
    }
}
