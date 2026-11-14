# Diagnostic only: test actual packing beyond the estimated LUT precheck.
# Always restore default resource checks. Never generate a bitstream here.
# vivado -mode batch -source probe_placement.tcl -tclargs OPT_DCP NEW_OUT
if {$argc != 2} {error "Expected OPT_DCP NEW_OUT"}
set input [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile $input] || [file exists $out]} {error "Expected input checkpoint and NEW output directory"}
file mkdir $out
file copy $input [file join $out input_optimized.dcp]
set_param general.maxThreads 4
open_checkpoint [file join $out input_optimized.dcp]
if {[get_property PART [current_design]] ne "xc7a35tcsg324-1"} {error "Unexpected FPGA part"}
report_utilization -file [file join $out utilization_before.rpt]
set_param drc.disableLUTOverUtilError 1
set rc [catch {place_design} detail]
# Do this even if placement fails; subsequent checks use the default severity.
set_param drc.disableLUTOverUtilError 0
set f [open [file join $out result.txt] w]
puts $f "placement_completed=[expr {!$rc}]"
puts $f "resource_check_override_restored=1"
if {$rc} {puts $f "error=$detail"}
close $f
report_utilization -file [file join $out utilization_after_attempt.rpt]
report_drc -file [file join $out drc_default.rpt]
if {$rc} {error "Diagnostic placement failed: $detail"}
write_checkpoint -force [file join $out placed.dcp]
report_timing_summary -delay_type min_max -file [file join $out timing_placed.rpt]
puts "DIAGNOSTIC_PLACEMENT_COMPLETED; inspect default DRC, not a board-ready result"
