# Measure placed cell rectangles directly. Keep IO/bond overlap and fillers
# separate from standard cells, and avoid mixing logical-library area metrics
# with the actual SRAM outline used by floorplanning.
proc report_implemented_area {directory} {
    set counts [dict create]
    set representative [dict create]
    foreach instance [dbGet top.insts] cell [dbGet top.insts.cell] {
        dict incr counts $cell
        if {![dict exists $representative $cell]} {dict set representative $cell $instance}
    }
    set total_area [dict create standard 0.0 sram 0.0 fillers 0.0 io_other 0.0]
    set total_count [dict create standard 0 sram 0 fillers 0 io_other 0]
    set details [open $directory/13_cell_footprints.tsv w]
    puts $details "cell\tgroup\tinstances\tsingle_bbox_um2"
    dict for {cell count} $counts {
        set name [lindex [dbGet $cell.name] 0]
        set instance [dict get $representative $cell]
        set box [lindex [dbGet $instance.box] 0]
        lassign $box x0 y0 x1 y1
        set area [expr {($x1-$x0)*($y1-$y0)}]
        if {$name eq "RA1SHD_2048x32M8"} {
            set group sram
        } elseif {[regexp {^FILL[0-9]+BWP7T$} $name]} {
            set group fillers
        } elseif {[dbGet $cell.baseClass] eq "core"} {
            set group standard
        } else {
            set group io_other
        }
        dict set total_area $group [expr {[dict get $total_area $group]+$area*$count}]
        dict incr total_count $group $count
        puts $details "$name\t$group\t$count\t$area"
    }
    close $details
    set report [open $directory/13_implemented_footprint.rpt w]
    puts $report "# Placed bounding-box areas; standard includes clock/tie/tap/antenna support, excludes core fillers."
    puts $report "# io_other is a sum of rectangles, not a union; IO/bond pads intentionally overlap."
    foreach group {standard sram fillers io_other} {
        puts $report "${group}_count [dict get $total_count $group]"
        puts $report "${group}_area_um2 [dict get $total_area $group]"
    }
    close $report
}
