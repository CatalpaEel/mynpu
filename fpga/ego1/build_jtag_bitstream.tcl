set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir create_project.tcl]
set_param general.maxThreads 4
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} { error "JTAG synthesis failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} { error "JTAG implementation failed" }
open_run impl_1
set out_dir [file join $script_dir build]
file mkdir $out_dir
set stem ego1_jtag_$::JTAG_LAYOUT
report_timing_summary -file [file join $out_dir ${stem}_timing.rpt]
report_utilization -file [file join $out_dir ${stem}_utilization.rpt]
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} { error "JTAG setup/hold timing failed" }
file copy -force [file join $project_dir $project_name.runs impl_1 ego1_soc_top.bit] [file join $out_dir ${stem}.bit]
puts "JTAG_BITSTREAM: [file join $out_dir ${stem}.bit]"
close_project
