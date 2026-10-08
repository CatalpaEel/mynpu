# Re-apply the static topology-strap timing contract to an existing route.
set root [file normalize [file join [file dirname [info script]] ..]]
set r [file join $root reports noc]
set_param general.maxThreads 4
open_checkpoint $r/node_routed.dcp
set_false_path -from [get_ports {node_x_i[*] node_y_i[*] port_enable_i[*] mesh_width_i[*] mesh_height_i[*] ddr_present_i}]
write_checkpoint -force $r/node_routed.dcp
report_utilization -file $r/utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $r/timing_routed.rpt
report_drc -file $r/drc_routed.rpt
set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "NOC_NODE_SETUP_SLACK=$setup"
puts "NOC_NODE_HOLD_SLACK=$hold"
if {$setup<0 || $hold<0} {error "NoC node implementation failed timing"}
