# Remove only redundant M1/M2 via arrays at the core row boundaries. A wider
# same-net array must contain BOTH metal enclosures of the smaller array.
# Keep all wires, larger arrays and higher-layer vias. This addresses duplicate
# followpin/pad-stripe contacts without deleting the surrounding power grid.
namespace eval mynpu_pg_cleanup {
    proc contains {outer inner} {
        lassign $outer ax ay bx by
        lassign $inner cx cy dx dy
        return [expr {$cx >= $ax-0.001 && $cy >= $ay-0.001 && $dx <= $bx+0.001 && $dy <= $by+0.001}]
    }
    proc run {} {
        lassign [lindex [dbGet top.fPlan.coreBox] 0] x0 y0 x1 y1
        set areas [list [list $x0 [expr {$y0-0.5}] $x1 [expr {$y0+0.5}]] [list $x0 [expr {$y1-0.5}] $x1 [expr {$y1+0.5}]]]
        set records {}
        foreach v [dbQuery -areas $areas -objType sViaInst] {
            if {![string match VIAGEN12_* [dbGet $v.via.name]]} {continue}
            set net [dbGet $v.net.name]
            if {$net ni {VDD VSS}} {continue}
            set bot [lindex [dbGet $v.botRects] 0]
            set top [lindex [dbGet $v.topRects] 0]
            if {[llength $bot]!=1 || [llength $top]!=1} {continue}
            set cuts [llength [lindex [dbGet $v.cutRects] 0]]
            lappend records [list $v $net $cuts [lindex $bot 0] [lindex $top 0]]
        }
        set remove {}
        foreach small $records {
            lassign $small sv sn sc sb st
            foreach large $records {
                lassign $large lv ln lc lb lt
                if {$sn eq $ln && $lc > $sc && [contains $lb $sb] && [contains $lt $st]} {
                    lappend remove $sv
                    puts "PG_REDUNDANT_VIA net=$sn small=[dbGet $sv.via.name] pt=[dbGet $sv.pt] cuts=$sc retained_cuts=$lc"
                    break
                }
            }
        }
        set remove [lsort -unique $remove]
        foreach v $remove {
            deselectAll
            dbSelectObj $v
            editDelete -selected -type Special -object_type Via
        }
        deselectAll
        set remaining [dbQuery -areas $areas -objType sViaInst]
        foreach v $remove {if {[lsearch -exact $remaining $v]>=0} {error "Redundant via deletion failed: $v"}}
        puts "PG_EDGE_CLEANUP_REMOVED [llength $remove]"
        return [llength $remove]
    }
}
mynpu_pg_cleanup::run
