set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/chip_synth
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
file mkdir $out
set_db max_cpus_per_server 8
set_db design_process_node 180
read_libs [list $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib $macro/RA1SHD_2048x32M8_tt_1p8_25C_syn.lib]
read_physical -lef [list $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef $macro/RA1SHD_2048x32M8.vclef $macro/RA1SHD_2048x32M8_ant.lef]
read_hdl -sv -define EDA_POSTSYN_CORE [list $run_root/mynpu/synth/mynpu_soc_top.postsyn.v $run_root/scripts/mynpu_asic_top.sv]
elaborate mynpu_asic_top
read_sdc $run_root/scripts/chip.sdc
syn_generic
syn_map
syn_opt
write_hdl > $out/mynpu_asic_top.postsyn.v
write_sdc > $out/mynpu_asic_top.sdc
write_db -all_root_attributes -to_file $out/optimized.genus.db -script $out/optimized_root.tcl
check_design > $out/check_design.rpt
check_design -unresolved > $out/unresolved.rpt
report_area > $out/area.rpt
report_timing -max_paths 10 > $out/timing.rpt
report_qor > $out/qor.rpt
puts FLOW_STAGE_OK_CHIP_SYNTHESIS
exit
