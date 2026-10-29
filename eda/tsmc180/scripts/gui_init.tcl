# Adapted to the current mynpu design from the Lab 4 procedure.
# Fixed 2000um die; nine signal pads; two SRAM macros; single TT analysis.
if {[dbGet top.name] ni {0x0 {}}} {error "Design already loaded; do not initialize twice."}
set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
file mkdir $out/checkpoints $out/reports $out/outputs
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
setMultiCpuUsage -localCpu 8
set init_verilog $run_root/mynpu/chip_synth/mynpu_asic_top.postsyn.v
set init_top_cell mynpu_asic_top
set init_lef_file [list $stdroot/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef $pdk/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/tpd018nv_6lm.lef $pdk/tpd018nv_280a/TSMCHOME/digital/Back_End/lef/tpd018nv_280a/mt_2/6lm/lef/antenna_6lm.lef $pdk/tpb018v_180a/TSMCHOME/digital/Back_End/lef/tpb018v_180a/cup/6lm/lef/tpb018v_6lm.lef $macro/RA1SHD_2048x32M8.vclef $macro/RA1SHD_2048x32M8_ant.lef]
set init_mmmc_file $run_root/scripts/chip_mmmc.tcl
set init_pwr_net VDD
set init_gnd_net VSS
setLibraryUnit -cap 1pf -time 1ns
init_design
setDesignMode -process 180 -bottomRoutingLayer METAL2 -topRoutingLayer METAL6
setAnalysisMode -analysisType onChipVariation -cppr both
setDelayCalMode -SIAware false
puts FLOW_STAGE_OK_CHIP_IMPORT
saveDesign $out/checkpoints/00_imported.enc
puts "GUI import ready: no floorplan or IO has been added."
