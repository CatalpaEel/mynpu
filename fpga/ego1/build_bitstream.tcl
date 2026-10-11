# Build the EGo1 bitstream after create_project.tcl.
# Usage: vivado -mode batch -source fpga/ego1/build_bitstream.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir vivado]]
set project_file [file join $project_dir ego1_mynpu.xpr]

if {![file exists $project_file]} {
    source [file join $script_dir create_project.tcl]
} else {
    open_project $project_file
}

set_param general.maxThreads 4
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Vivado synthesis failed; inspect [file join $project_dir ego1_mynpu.runs synth_1 runme.log]"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "Vivado implementation/bitstream failed; inspect impl_1 runme.log"
}

set bit_src [file join $project_dir ego1_mynpu.runs impl_1 ego1_soc_top.bit]
set out_dir [file normalize [file join $script_dir build]]
file mkdir $out_dir
file copy -force $bit_src [file join $out_dir ego1_soc_top.bit]
puts "BITSTREAM: [file join $out_dir ego1_soc_top.bit]"
close_project
