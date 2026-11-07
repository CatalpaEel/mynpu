set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
set dest $out/outputs/final
file mkdir $dest
source $run_root/scripts/flow_paths.tcl
set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
defOut -routing $dest/mynpu_asic_top.def
set physical_excludes {FILL1BWP7T FILL2BWP7T FILL4BWP7T FILL8BWP7T FILL16BWP7T FILL32BWP7T FILL64BWP7T TAPCELLBWP7T PCORNER PFILLER20 PFILLER10 PFILLER5 PFILLER1 PFILLER05 PFILLER0005 PRCUT PAD60LU_OBV}
saveNetlist $dest/mynpu_asic_top.flat_lvs.v -excludeLeafCell -flat -phys -excludeCellInst $physical_excludes
saveNetlist $dest/mynpu_asic_top.hier_postpnr.v -excludeLeafCell -topModuleFirst -removePowerGround -excludeCellInst [concat $physical_excludes {DCAPBWP7T DCAP4BWP7T DCAP8BWP7T DCAP16BWP7T DCAP32BWP7T DCAP64BWP7T ANTENNABWP7T}]
write_sdc -view func_tt_io > $dest/mynpu_asic_top.sdc
write_sdc -path_adjust_only > $dest/mynpu_asic_top.path_adjust.tcl
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
if {![dbGet top.statusRCExtracted]} {extractRC}
rcOut -view func_tt_io -cUnit pF -spef $dest/mynpu_asic_top.spef.gz
write_sdf -min_view func_tt_io -typ_view func_tt_io -max_view func_tt_io -recompute_delay_calc $dest/mynpu_asic_top.sdf.gz
write_lef_abstract -5.8 -cutObsMinSpacing -specifyTopLayer METAL6 $dest/mynpu_asic_top.lef
setStreamOutMode -labelAllPinShape true -virtualConnection false
streamOut $dest/mynpu_asic_top.gds.gz -mapFile $stdroot/Back_End/lef/tcb018gbwp7t_270a/techfiles/gds2.map -merge [list $stdroot/Back_End/gds/tcb018gbwp7t_270a/tcb018gbwp7t.gds $macro/RA1SHD_2048x32M8.gds $pdk/tpd018nv_280a/TSMCHOME/digital/Back_End/gds/tpd018nv_280a/mt_2/6lm/tpd018nv.gds $pdk/tpb018v_180a/TSMCHOME/digital/Back_End/gds/tpb018v_180a/cup/6lm/tpb018v.gds] -mode ALL -units 2000
saveDesign $out/checkpoints/14_exported.enc
puts FLOW_STAGE_OK_CHIP_FINAL_EXPORT
exit
