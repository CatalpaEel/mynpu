set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/08_post_tie.enc.dat mynpu_asic_top
source $run_root/scripts/fix_pg_edge_vias.tcl
verify_drc -check_only special -report $out/reports/09_pg_edge_cleanup_drc.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/09_pg_edge_cleanup_connectivity.rpt
setMultiCpuUsage -localCpu 8
setAnalysisMode -analysisType onChipVariation -cppr both
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
set_ccopt_property primary_delay_corner delay_tt_io
set_ccopt_property buffer_cells {CKBD1BWP7T CKBD2BWP7T CKBD4BWP7T CKBD6BWP7T CKBD8BWP7T CKBD10BWP7T CKBD12BWP7T}
set_ccopt_property inverter_cells {INVD1BWP7T INVD2BWP7T INVD4BWP7T INVD8BWP7T INVD12BWP7T}
set_ccopt_property update_io_latency false
set_ccopt_property force_update_io_latency false
create_ccopt_clock_tree_spec -views {func_tt_io}
set_interactive_constraint_modes [all_constraint_modes -active]
set_clock_uncertainty -setup 0.47 [get_clocks {sys_clk jtag_clk}]
set_clock_uncertainty -hold 0.2 [get_clocks {sys_clk jtag_clk}]
set_input_transition 0.5 [get_ports {clk_i tck_i}]
set_interactive_constraint_modes {}
foreach tree {sys_clk jtag_clk} {
    set_ccopt_property source_output_max_trans 0.5 -clock_tree $tree
    set_ccopt_property source_max_capacitance 5.0 -clock_tree $tree
}
ccopt_design -check_prerequisites
saveDesign $out/checkpoints/09_pre_cts.enc
ccopt_design
set_interactive_constraint_modes [all_constraint_modes -active]
set_global timing_io_use_clock_network_latency always
set_propagated_clock [get_clocks {sys_clk jtag_clk}]
set_interactive_constraint_modes {}
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
checkPlace $out/reports/10_cts_place.rpt -ignoreOutOfCore
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/10_cts_pg.rpt
timeDesign -postCTS -expandedViews -outDir $out/reports/postCTS
timeDesign -postCTS -hold -expandedViews -outDir $out/reports/postCTS_hold
saveDesign $out/checkpoints/10_post_cts.enc
puts FLOW_STAGE_OK_CHIP_CTS_COMMANDS_COMPLETED
exit
