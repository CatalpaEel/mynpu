# CPU-SRAM / MMIO-configured array ASIC shell. Stream caches hold data only;
# their configured capacity is frozen in inputs/source_manifest.json.
set run_root [file normalize [file join [file dirname [info script]] ..]]
set project_root $run_root/inputs/mynpu
set out $run_root/mynpu/chip_synth
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
file mkdir $out
set fast_area [expr {[info exists ::env(FLOW_FAST_AREA)] && $::env(FLOW_FAST_AREA) eq "1"}]
set_db max_cpus_per_server 4
set_db design_process_node 180
set_db hdl_parameterize_module_name false
set_db init_hdl_search_path [list $project_root $project_root/third_party/lab3/soc/rtl/include $project_root/third_party/lab3/cpu_cv32e40p/include]
read_libs [list $stdroot/Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib $macro/RA1SHD_2048x32M8_tt_1p8_25C_syn.lib]
read_physical -lef [list $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef $macro/RA1SHD_2048x32M8.vclef $macro/RA1SHD_2048x32M8_ant.lef]
set sources {}
set f [open $project_root/sim/soc.f r]
foreach line [split [read $f] \n] {
    set line [string trim $line]
    if {$line eq "" || [string match +incdir+* $line]} {continue}
    if {$line eq "cnn_npu_int8/rtl/torus_pe.sv" && [file exists $run_root/inputs/mapped_torus_pe.v]} {
        lappend sources $run_root/inputs/mapped_torus_pe.v $run_root/inputs/mapped_torus_wrapper.sv
        puts TORUS_USING_VERIFIED_MAPPED_PE
        continue
    }
    if {$line eq "cnn_npu_int8/rtl/cnn_npu_tile.sv" && [file exists $run_root/inputs/mapped_pe.v]} {
        lappend sources $run_root/inputs/mapped_pe.v
        puts GRID_USING_FROZEN_MAPPED_PE
        continue
    }
    lappend sources $project_root/$line
}
close $f
lappend sources $project_root/rtl/mynpu_sram_2048x32_asic.sv $run_root/scripts/mynpu_asic_top.sv
read_hdl -sv -define SYNTHESIS $sources
puts GRID_FULL_READ_HDL_PASS
elaborate mynpu_asic_top
check_design > $out/elaborated_check_design.rpt
check_design -unresolved > $out/elaborated_unresolved.rpt
if {!$fast_area} {write_db -all_root_attributes -to_file $out/elaborated.genus.db -script $out/elaborated_root.tcl}
puts GRID_FULL_ELABORATION_PASS
read_sdc $run_root/scripts/chip.sdc
set effort low
if {[info exists ::env(FLOW_SYNTH_EFFORT)]} {set effort $::env(FLOW_SYNTH_EFFORT)}
if {$effort ni {low medium high}} {error "FLOW_SYNTH_EFFORT must be low, medium or high"}
set_db syn_generic_effort $effort
set_db syn_map_effort $effort
set_db syn_opt_effort $effort
syn_generic
report_area > $out/generic_area.rpt
if {!$fast_area} {write_db -all_root_attributes -to_file $out/generic.genus.db -script $out/generic_root.tcl}
puts GRID_FULL_GENERIC_PASS
syn_map
report_area > $out/mapped_area.rpt
write_hdl > $out/mynpu_asic_top.postsyn.v
write_sdc > $out/mynpu_asic_top.sdc
if {!$fast_area} {write_db -all_root_attributes -to_file $out/mapped.genus.db -script $out/mapped_root.tcl}
puts GRID_FULL_MAPPED_PASS
if {$fast_area} {
    report_area > $out/area.rpt
    report_gates > $out/gates.rpt
    report_timing -max_paths 10 > $out/timing.rpt
    report_qor > $out/qor.rpt
    check_design > $out/check_design.rpt
    check_design -unresolved > $out/unresolved.rpt
    puts GRID_FAST_AREA_PASS
    exit
}
syn_opt
report_area > $out/area.rpt
report_gates > $out/gates.rpt
report_timing -max_paths 10 > $out/timing.rpt
report_qor > $out/qor.rpt
check_design > $out/check_design.rpt
check_design -unresolved > $out/unresolved.rpt
write_hdl > $out/mynpu_asic_top.postsyn.v
write_sdc > $out/mynpu_asic_top.sdc
write_db -all_root_attributes -to_file $out/optimized.genus.db -script $out/optimized_root.tcl
puts GRID_FULL_SYNTHESIS_PASS
exit
