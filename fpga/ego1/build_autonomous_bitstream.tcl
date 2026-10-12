# Build the EGo1 no-Debug autonomous bitstream.
set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir vivado_autonomous]]
set project_file [file join $project_dir ego1_mynpu_autonomous.xpr]
# Recreate the source/IP configuration so changes to the project script are
# picked up on every build, including an already-existing local project.
source [file join $script_dir create_autonomous_project.tcl]
set_param general.maxThreads 4
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} { error "autonomous synthesis failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} { error "autonomous implementation failed" }
set bit_src [file join $project_dir ego1_mynpu_autonomous.runs impl_1 ego1_autonomous_top.bit]
set out_dir [file normalize [file join $script_dir build]]
file mkdir $out_dir
file copy -force $bit_src [file join $out_dir ego1_autonomous_top.bit]
open_run impl_1
write_debug_probes -force [file join $out_dir ego1_autonomous_top.ltx]
report_timing_summary -file [file join $out_dir ego1_autonomous_timing.rpt]
report_utilization -file [file join $out_dir ego1_autonomous_utilization.rpt]
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {
    error "Autonomous design does not meet setup/hold timing"
}
puts "AUTONOMOUS_BITSTREAM: [file join $out_dir ego1_autonomous_top.bit]"
close_project
