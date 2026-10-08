set root [file normalize [file join [file dirname [info script]] ..]]
set r [file join $root reports noc]
file mkdir $r
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
source [file join $root build sources.tcl]
create_project -in_memory -part xc7a35tcsg324-1
add_files -norecurse $npu_sources
read_xdc [file join $root constraints noc_ooc.xdc]
set_property verilog_define {NPU_FPGA_TEST} [get_filesets sources_1]
set_param general.maxThreads 4
synth_design -top npu_noc_soc -part xc7a35tcsg324-1 -mode out_of_context
write_checkpoint -force $r/node_synth.dcp
write_verilog -force -mode funcsim $r/node_synth.v
report_utilization -file $r/utilization_synth.rpt
report_timing_summary -file $r/timing_synth.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $r/node_routed.dcp
report_utilization -file $r/utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $r/timing_routed.rpt
report_drc -file $r/drc_routed.rpt
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "NOC_NODE_SETUP_SLACK=$setup"
puts "NOC_NODE_HOLD_SLACK=$hold"
if {$setup<0 || $hold<0} {error "NoC node implementation failed timing"}
