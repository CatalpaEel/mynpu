# Run from a prepared build directory, or use build.py (no hardware connection).
set run_dir [file normalize [pwd]]
foreach name {implementation_pass.txt ego1_mynpu.bit ego1_mynpu.mcs} {
  file delete -force [file join $run_dir $name]
}
source [file join $run_dir sources.tcl]
create_project -force ego1_mynpu [file join $run_dir project] -part xc7a35tcsg324-1
set_property target_language Verilog [current_project]
set_property include_dirs [list [file join $run_dir include]] [get_filesets sources_1]
set_property verilog_define [concat NPU_FPGA_TEST $npu_defines] [get_filesets sources_1]
add_files -norecurse $npu_sources
add_files -fileset constrs_1 [file join $run_dir ego1.xdc]
set_property top ego1_soc_top [get_filesets sources_1]
update_compile_order -fileset sources_1
set_param general.maxThreads 4
file mkdir [file join $run_dir reports]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
report_utilization -hierarchical -file [file join $run_dir reports utilization_synth.rpt]
report_timing_summary -file [file join $run_dir reports timing_synth.rpt]
close_design
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
write_checkpoint -force [file join $run_dir ego1_routed.dcp]
report_utilization -hierarchical -file [file join $run_dir reports utilization_routed.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $run_dir reports timing_routed.rpt]
report_clock_interaction -file [file join $run_dir reports clock_interaction.rpt]
report_cdc -details -file [file join $run_dir reports cdc.rpt]
check_timing -verbose -file [file join $run_dir reports check_timing.rpt]
report_route_status -file [file join $run_dir reports route_status.rpt]
report_drc -file [file join $run_dir reports drc.rpt]
report_methodology -file [file join $run_dir reports methodology.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {![llength $setup] || ![llength $hold]} {error "No timed paths"}
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {
  error "Timing closure failed; refusing bitstream generation"
}
set violations [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
if {[llength $violations]} {error "Unresolved DRC violations: $violations"}
# write_bitstream additionally enforces the default Vivado bitstream DRCs.
write_bitstream -force [file join $run_dir ego1_mynpu.bit]
write_cfgmem -force -format mcs -interface SPIx4 -size 8 \
  -loadbit [list up 0x0 [file join $run_dir ego1_mynpu.bit]] \
  -file [file join $run_dir ego1_mynpu.mcs]
set f [open [file join $run_dir implementation_pass.txt] w]
puts $f "Vivado [version -short]; xc7a35tcsg324-1; 50 MHz"
puts $f "setup_slack_ns=[get_property SLACK $setup]"
puts $f "hold_slack_ns=[get_property SLACK $hold]"
close $f
close_project
