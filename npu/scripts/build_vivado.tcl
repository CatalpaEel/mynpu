set npu_root [file normalize [file join [file dirname [info script]] ..]]
set project_file [file join $npu_root .. xc7a35t.xpr]
set report_dir [file join $npu_root reports]
file mkdir $report_dir
cd [file join $npu_root build]
if {[version -short] ne "2025.2"} { error "Vivado 2025.2 required" }
source sources.tcl
open_project $project_file
set_property PART xc7a35tcsg324-1 [current_project]
foreach pattern {*/npu_rom.sv */cv32e40p_fpga_clock_gate.sv */boot.hex} {
  set stale [get_files -quiet $pattern]
  if {[llength $stale]} { remove_files $stale }
}
add_files -norecurse $npu_sources
set mnist_artifacts [file join $npu_root mnist artifacts]
foreach memfile [glob -directory $mnist_artifacts *.hex] {
  add_files -fileset sim_1 -norecurse $memfile
  set_property file_type {Memory Initialization Files} [get_files $memfile]
  set_property used_in_synthesis false [get_files $memfile]
}
add_files -fileset sim_1 -norecurse [file join $mnist_artifacts test_meta.svh]
set_property include_dirs [list $mnist_artifacts] [get_filesets sim_1]
add_files -fileset constrs_1 -norecurse [file join $npu_root constraints npu_ooc.xdc]
add_files -fileset sim_1 -norecurse [file join $npu_root tb tb_npu_soc.sv]
set_property top npu_soc [get_filesets sources_1]
add_files -fileset sim_1 -norecurse [file join $npu_root tb tb_mnist.sv]
add_files -fileset sim_1 -norecurse [file join $npu_root tb tb_mnist_stream.sv]
add_files -fileset sim_1 -norecurse [file join $npu_root tb tb_mnist_latency.sv]
set_property top tb_mnist_stream [get_filesets sim_1]
set_property generic {} [get_filesets sources_1]
set_property verilog_define {NPU_FPGA_TEST} [get_filesets sources_1]
set_property verilog_define {NPU_FPGA_TEST} [get_filesets sim_1]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_param general.maxThreads 4
synth_design -top npu_soc -part xc7a35tcsg324-1 -mode out_of_context
write_checkpoint -force [file join $report_dir npu_synth.dcp]
write_verilog -force -mode funcsim [file join $report_dir npu_synth.v]
report_utilization -file [file join $report_dir utilization_synth.rpt]
report_timing_summary -file [file join $report_dir timing_synth.rpt]
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $report_dir npu_routed.dcp]
report_utilization -file [file join $report_dir utilization_routed.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $report_dir timing_routed.rpt]
report_drc -file [file join $report_dir drc_routed.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
set worst_setup [get_timing_paths -delay_type max -max_paths 1]
set worst_hold [get_timing_paths -delay_type min -max_paths 1]
puts "NPU_BUILD_PART=[get_property PART [current_design]]"
puts "NPU_SETUP_SLACK=[get_property SLACK $worst_setup]"
puts "NPU_HOLD_SLACK=[get_property SLACK $worst_hold]"
if {[get_property SLACK $worst_setup] < 0 || [get_property SLACK $worst_hold] < 0} {
  error "NPU implementation failed timing constraints"
}
close_project
