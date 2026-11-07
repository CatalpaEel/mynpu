# Read-only attribution on the exact final mapped database. All units are um^2.
# Usage: NPU_AREA_RUN=/absolute/run genus -no_gui -batch -files this-file.tcl
set run [file normalize $::env(NPU_AREA_RUN)]
read_db [file join $run optimized.db]
set out [open [file join $run reports leaf_area.tsv] w]
foreach inst [get_db insts] {
 puts $out "[get_db $inst .name]\t[get_db $inst .base_cell.name]\t[get_db $inst .base_cell.area]"
}
close $out
puts LEAF_AREA_EXPORT_PASS
exit
