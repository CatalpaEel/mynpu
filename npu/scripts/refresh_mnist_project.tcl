set root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root .. xc7a35t.xpr]
source [file join $root build sources.tcl]
foreach old [get_files -quiet] {
  if {[string match "*/npu/rtl/*" $old] && [lsearch -exact $npu_sources $old] < 0} {
    remove_files $old
  }
}
foreach source_file $npu_sources {
  if {![llength [get_files -quiet $source_file]]} {add_files -norecurse $source_file}
}
set_property verilog_define [concat {NPU_FPGA_TEST} $npu_defines] [get_filesets sources_1]
set_property verilog_define [concat {NPU_FPGA_TEST} $npu_defines] [get_filesets sim_1]
set artifacts [file join $root mnist artifacts]
foreach memfile [glob -directory $artifacts *.hex] {
  if {![llength [get_files -quiet $memfile]]} {add_files -fileset sim_1 -norecurse $memfile}
  set_property file_type {Memory Initialization Files} [get_files $memfile]
  set_property used_in_synthesis false [get_files $memfile]
}
set stream_tb [file join $root tb tb_mnist_stream.sv]
if {![llength [get_files -quiet $stream_tb]]} {add_files -fileset sim_1 -norecurse $stream_tb}
set latency_tb [file join $root tb tb_mnist_latency.sv]
if {![llength [get_files -quiet $latency_tb]]} {add_files -fileset sim_1 -norecurse $latency_tb}
set_property top tb_mnist_latency [get_filesets sim_1]
set_property include_dirs [list $artifacts] [get_filesets sim_1]
update_compile_order -fileset sim_1
close_project
