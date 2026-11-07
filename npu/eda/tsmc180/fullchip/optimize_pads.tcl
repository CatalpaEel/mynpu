# After placement, choose legal signal PAD slots using actual core endpoints.
set signal_plan {clk_i top 300 in rst_ni top 1600 in tck_i bottom 250 in tms_i bottom 450 in td_i bottom 1450 in td_o bottom 1700 out boot_ready_i left 300 in npu_irq_o right 300 out cpu_debug_halted_o right 1600 out}
set points [open $out/outputs/pad_endpoints.tsv w]
foreach {port side pos direction} $signal_plan {
    set terminal [expr {$direction eq "in" ? "C" : "I"}]
    set term [dbGet top.insts.instTerms.name i_pad_$port/$terminal -p]
    set net [dbGet $term.net]
    foreach t [dbGet $net.instTerms] {
        set name [dbGet $t.inst.name]
        if {[string match i_pad_* $name] || [string match IOF_* $name] || [string match bond_* $name]} {continue}
        lassign [lindex [dbGet $t.pt] 0] x y
        puts $points "$port $x $y"
    }
}
close $points
exec /usr/bin/python3.12 $run_root/scripts/optimize_pads.py --points $out/outputs/pad_endpoints.tsv --out $out/outputs/pad_moves.tcl
source $out/outputs/pad_moves.tcl
# Native power pads stay fixed; rebuild only the IO fillers and signal bonds.
foreach name [dbGet top.insts.name IOF_*] {if {$name ne "0x0"} {deleteInst $name}}
array set side_ori {top R180 bottom R0 left R270 right R90}
foreach {port side pos direction} $optimized_signal_plan {
    if {$side in {top bottom}} {
        set x $pos;set y [expr {$side eq "top" ? 1885 : 0}]
        set bx $pos;set by [expr {$side eq "top" ? 1926.84 : 0}]
    } else {
        set x [expr {$side eq "right" ? 1885 : 0}];set y $pos
        set bx [expr {$side eq "right" ? 1926.84 : 0}];set by $pos
    }
    placeInstance i_pad_$port $x $y $side_ori($side) -fixed
    deleteInst bond_i_pad_$port
    addInst -physical -cell PAD60LU_OBV -inst bond_i_pad_$port -loc [list $bx $by] -ori $side_ori($side) -place_status fixed -dontSnapToPlacementGrid
    # Replace the external pin shape at its new bond position.
    set nx [expr {$side in {top bottom} ? $pos+10 : ($side eq "right" ? 1998 : 1)}]
    set ny [expr {$side in {left right} ? $pos+10 : ($side eq "top" ? 1998 : 1)}]
    # These are bond labels inside the PAD terminal, not boundary pins. Default
    # TRACK/fixOverlap placement can move an output to a neighboring IO filler.
    editPin -pin $port -layer METAL4 -assign [list $nx $ny] -side INSIDE -snap MGRID -fixOverlap 0 -pinWidth 1 -pinDepth 1 -fixedPin
}
# Register native IO instances only, excluding overlaid physical bond windows.
set pad_plan {}
foreach {port side pos direction} $optimized_signal_plan {lappend pad_plan [list i_pad_$port PDDW0204CDG $side $pos]}
foreach side {top bottom left right} {
    foreach {suffix cell pos} {vss_1 PVSS1CDG 650 vss_2 PVSS1CDG 750 vssio PVSS2CDG 850 vdd_1 PVDD1CDG 950 vdd_2 PVDD1CDG 1050 vddio PVDD2CDG 1150 poc PVDD2POC 1250} {
        lappend pad_plan [list i_pad_${side}_$suffix $cell $side $pos]
    }
}
set file [open $out/outputs/io_optimized.io w]
puts $file "(globals\n version = 3\n io_order = default\n)\n(iopad"
foreach {side corner ori} {topright corner_tr R180 topleft corner_tl MX bottomleft corner_bl R0 bottomright corner_br MY} {
    puts $file [format { (%s (inst name="%s" cell="PCORNER" orientation=%s place_status=fixed))} $side $corner $ori]
}
foreach side {top bottom left right} {
    puts $file " ($side"
    foreach row [lsort -real -index 3 $pad_plan] {
        lassign $row name cell actual_side pos
        if {$actual_side ne $side} {continue}
        puts $file [format {  (inst name="%s" cell="%s" offset=%.6f indent=0 orientation=%s place_status=fixed)} $name $cell $pos $side_ori($side)]
    }
    puts $file " )"
}
puts $file ")"
close $file
loadIoFile $out/outputs/io_optimized.io -noAdjustDieSize -specifiedIosOnly
foreach side {top bottom left right} {
    addIoFiller -cell {PFILLER20 PFILLER10 PFILLER5 PFILLER1 PFILLER05 PFILLER0005} -prefix IOF_$side -side $side -fillerOrient $side_ori($side)
}
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
defOut $out/outputs/07_io_optimized.def
puts FLOW_PAD_DISCRETE_ASSIGNMENT_COMPLETED
