# Small, independent PE area diagnostic. Whole-SoC mapped area is reported by
# synth_current_grid.tcl; these block numbers must not be substituted for it.
set run_root [file normalize [file join [file dirname [info script]] ..]]
source $run_root/scripts/flow_paths.tcl
set out $run_root/mynpu/tile_synth
file mkdir $out
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
set_db max_cpus_per_server 4
set_db hdl_parameterize_module_name false
read_libs $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib
read_physical -lef $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef
read_hdl -sv $run_root/inputs/mynpu/cnn_npu_int8/rtl/cnn_npu_tile.sv
elaborate cnn_npu_tile
create_clock -name sys_clk -period 20 [get_ports clk_i]
set_clock_uncertainty -setup 0.52 [get_clocks sys_clk]
set_false_path -from [get_ports rst_ni]
set_input_delay 0.5 -clock sys_clk [get_ports {load_i mac_i grid_i activation_i* weight_i* bias_i* operation_i* operand_a_i* operand_b_i*}]
set_output_delay 0.5 -clock sys_clk [get_ports result_o*]
set_input_transition 0.2 [all_inputs]
set_load 0.02 [all_outputs]
set_db syn_generic_effort low
set_db syn_map_effort low
syn_generic
syn_map
report_area > $out/area.rpt
report_gates > $out/gates.rpt
report_timing -max_paths 5 > $out/timing.rpt
check_design -unresolved > $out/unresolved.rpt
write_hdl > $out/tile.postsyn.v
puts PE_TILE_FAST_AREA_PASS
exit
