set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/06_powerplan.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setDelayCalMode -SIAware false
setOptMode -maxDensity 0.90 -fixHoldAllowSetupTnsDegrade false
setPlaceMode -place_detail_preroute_as_obs {} -place_detail_use_check_drc true
setPlaceMode -place_global_cong_effort high
# Limit local hot spots; setOptMode -maxDensity only bounds optimization growth.
setPlaceMode -place_global_max_density 0.82
setPlaceMode -place_global_ignore_scan true -place_global_reorder_scan false
place_opt_design
checkPlace $out/reports/07_place_check.rpt -ignoreOutOfCore
saveDesign $out/checkpoints/07_placed.enc
puts FLOW_STAGE_OK_CHIP_PLACEMENT_COMMAND_COMPLETED
setTieHiLoMode -cell {TIEHBWP7T TIELBWP7T} -maxFanout 1 -maxDistance 100
addTieHiLo -cellPin {PDDW0204CDG:I PDDW0204CDG:DS PDDW0204CDG:OEN PDDW0204CDG:PE PDDW0204CDG:IE}
setTieHiLoMode -cell {TIEHBWP7T TIELBWP7T} -maxFanout 8 -maxDistance 50
addTieHiLo -keepExisting true -excludePin $out/outputs/tie_supply_exclude.txt
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
refinePlace
checkPlace $out/reports/08_post_tie_place.rpt -ignoreOutOfCore
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/08_post_tie_pg.rpt
timeDesign -preCTS -expandedViews -outDir $out/reports/preCTS
saveNetlist $out/outputs/08_post_tie.v -phys
saveDesign $out/checkpoints/08_post_tie.enc
puts FLOW_STAGE_OK_CHIP_TIE_PRECTS_COMMANDS_COMPLETED
exit
