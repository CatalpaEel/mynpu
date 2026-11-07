set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/10_post_cts.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setAnalysisMode -analysisType onChipVariation -cppr both
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
setOptMode -fixHoldAllowSetupTnsDegrade false
optDesign -postCTS -hold -expandedViews -outDir $out/reports/postCTS_holdFix
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
checkPlace $out/reports/11_holdfix_place.rpt -ignoreOutOfCore
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/11_holdfix_pg.rpt
timeDesign -postCTS -expandedViews -outDir $out/reports/postCTS_holdFix_setup_check
timeDesign -postCTS -hold -expandedViews -outDir $out/reports/postCTS_holdFix_hold_check
saveDesign $out/checkpoints/11_pre_route.enc
puts FLOW_STAGE_OK_CHIP_CTS_HOLDFIX_COMMANDS_COMPLETED
exit
