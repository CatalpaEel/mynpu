# Independent mapped PE, reusable only after source/library hash verification.
# Full-chip timing/area is always measured again after reconnecting the array.
set run_root [file normalize [file join [file dirname [info script]] ..]]
source $run_root/scripts/flow_paths.tcl
set out $run_root/mynpu/torus_pe_synth
file mkdir $out
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
set_db max_cpus_per_server 4
set_db hdl_parameterize_module_name false
read_libs $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib
read_physical -lef $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef
read_hdl -sv $run_root/inputs/mynpu/cnn_npu_int8/rtl/torus_pe.sv
elaborate torus_pe
create_clock -name sys_clk -period 20 [get_ports clk_i]
set_clock_uncertainty -setup 0.52 [get_clocks sys_clk]
set_false_path -from [get_ports rst_ni]
set_input_delay 0.5 -clock sys_clk [get_ports {execute_i operation_i* destination_i* operand_a_i* operand_b_i* load0_i load1_i load0_reg_i* load1_reg_i* load0_data_i* load1_data_i* load0_be_i* load1_be_i*}]
set_output_delay 0.5 -clock sys_clk [all_outputs]
set_input_transition 0.2 [all_inputs]
set_load 0.02 [all_outputs]
set_db syn_generic_effort medium
set_db syn_map_effort medium
set_db syn_opt_effort medium
syn_generic
syn_map
syn_opt
report_area > $out/area.rpt
report_gates > $out/gates.rpt
report_timing -max_paths 5 > $out/timing.rpt
check_design -unresolved > $out/unresolved.rpt
write_hdl > $out/torus_pe.postsyn.v
write_sdc > $out/torus_pe.sdc
puts TORUS_PE_MAPPED_PASS
exit
