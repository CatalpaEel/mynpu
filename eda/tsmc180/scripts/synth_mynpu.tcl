set run_root [file normalize [file join [file dirname [info script]] ..]]
set project_root $run_root/inputs/mynpu
set out $run_root/mynpu/synth
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
file mkdir $out
set_db max_cpus_per_server 8
set_db design_process_node 180
set_db hdl_parameterize_module_name false
set_db init_hdl_search_path [list $project_root $project_root/third_party/lab3/soc/rtl/include $project_root/third_party/lab3/cpu_cv32e40p/include]
read_libs [list $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib $macro/RA1SHD_2048x32M8_tt_1p8_25C_syn.lib]
read_physical -lef [list $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef $macro/RA1SHD_2048x32M8.vclef $macro/RA1SHD_2048x32M8_ant.lef]
set sources {}
set f [open $project_root/sim/soc.f r]
foreach line [split [read $f] \n] {
    set line [string trim $line]
    if {$line eq "" || [string match +incdir+* $line]} { continue }
    lappend sources $project_root/$line
}
close $f
lappend sources $project_root/rtl/mynpu_sram_2048x32_asic.sv
read_hdl -sv -define SYNTHESIS $sources
elaborate mynpu_soc_top -parameters {{USE_ASIC_SRAM 1} {USE_FPGA_BRAM 0} {NPU_LANES 4} {CPU_SRAM_BYTES 8192} {NPU_SRAM_BYTES 8192}}
read_sdc $run_root/scripts/mynpu.sdc
check_design > $out/elaborated_check_design.rpt
check_design -unresolved > $out/elaborated_unresolved.rpt
check_timing_intent -verbose > $out/elaborated_timing_intent.rpt
puts FLOW_STAGE_OK_MYNPU_TSMC180_ELABORATION
set_db syn_generic_effort medium
set_db syn_map_effort medium
set_db syn_opt_effort medium
syn_generic
write_db -all_root_attributes -to_file $out/generic.genus.db -script $out/generic_root.tcl
puts FLOW_STAGE_OK_MYNPU_TSMC180_GENERIC
syn_map
write_db -all_root_attributes -to_file $out/mapped.genus.db -script $out/mapped_root.tcl
write_hdl > $out/mynpu_soc_top.preopt.v
write_sdc > $out/mynpu_soc_top.sdc
report_area > $out/preopt_area.rpt
puts FLOW_STAGE_OK_MYNPU_TSMC180_MAPPED
syn_opt
write_hdl > $out/mynpu_soc_top.postsyn.v
write_sdc > $out/mynpu_soc_top.sdc
write_sdf > $out/mynpu_soc_top.sdf
write_db -all_root_attributes -to_file $out/optimized.genus.db -script $out/optimized_root.tcl
check_design > $out/check_design.rpt
check_design -unresolved > $out/unresolved.rpt
check_timing_intent -verbose > $out/timing_intent.rpt
report_area > $out/area.rpt
report_timing -max_paths 10 > $out/timing.rpt
report_qor > $out/qor.rpt
report_messages > $out/messages.rpt
puts FLOW_STAGE_OK_MYNPU_TSMC180_SYNTHESIS
exit
