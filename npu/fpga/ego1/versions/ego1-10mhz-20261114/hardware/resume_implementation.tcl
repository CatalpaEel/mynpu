set run_dir [file normalize [pwd]]
source [file join $run_dir sources.tcl]
open_project [file join $run_dir project ego1_mynpu.xpr]
set_param general.maxThreads 8
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 4

wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
set_param drc.disableLUTOverUtilError 0
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
puts $f "Vivado [version -short]; xc7a35tcsg324-1; $npu_system_mhz MHz"
puts $f "setup_slack_ns=[get_property SLACK $setup]"
puts $f "hold_slack_ns=[get_property SLACK $hold]"
puts $f "default_resource_drc_restored=1"
close $f
close_project
