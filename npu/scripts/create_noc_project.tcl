set root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root noc vivado]
set project_file [file join $project_dir noc_node.xpr]
if {[file exists $project_file]} {open_project $project_file} else {create_project noc_node $project_dir -part xc7a35tcsg324-1}
source [file join $root build sources.tcl]
add_files -norecurse $npu_sources
add_files -fileset constrs_1 -norecurse [file join $root constraints noc_ooc.xdc]
add_files -fileset sim_1 -norecurse [file join $root tb tb_noc_mesh.sv]
foreach memfile [glob -directory [file join $root mnist artifacts] *.hex] {
 add_files -fileset sim_1 -norecurse $memfile
 set_property file_type {Memory Initialization Files} [get_files $memfile]
 set_property used_in_synthesis false [get_files $memfile]
}
set_property top npu_noc_soc [get_filesets sources_1]
set_property top tb_noc_mesh [get_filesets sim_1]
set_property verilog_define {NPU_FPGA_TEST} [get_filesets sources_1]
set_property verilog_define {NPU_FPGA_TEST} [get_filesets sim_1]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
