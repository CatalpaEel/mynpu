set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/pnr
restoreDesign $out/checkpoints/13_finished.enc.dat mynpu_asic_top
setMultiCpuUsage -localCpu 8
setAnalysisMode -analysisType onChipVariation -cppr both
setExtractRCMode -engine postRoute -effortLevel low -tQuantusForPostRoute false
# A top-level port lies on its one native PAD metal terminal. Preserve the
# internal core nets; remove only unnecessary external PAD router excursions.
foreach port {clk_i rst_ni boot_ready_i tck_i tms_i td_i td_o npu_irq_o cpu_debug_halted_o} {
    set net [dbGetNetByName $port]
    if {[llength [dbGet $net.instTerms]] != 1 || [dbGet $net.instTerms.name] ne "i_pad_$port/PAD" || [dbGet $net.terms.name] ne $port} {error "Unexpected external PAD topology $port"}
    set objects [concat [dbGet -e $net.wires] [dbGet -e $net.vias]]
    if {[llength $objects]} {
        deselectAll
        foreach obj $objects {dbSelectObj $obj}
        editDelete -selected -type Regular
    }
}
deselectAll
checkPlace $out/reports/13_final_place.rpt -ignoreOutOfCore
verify_drc -check_only default -limit 100000 -report $out/reports/13_final_drc.rpt
verifyConnectivity -type regular -error 100000 -report $out/reports/13_final_signal.rpt
verifyConnectivity -type special -net {VDD VSS} -allPGPinPort -error 100000 -report $out/reports/13_final_pg.rpt
verifyProcessAntenna -report $out/reports/13_final_antenna.rpt
timeDesign -postRoute -expandedViews -outDir $out/reports/final_setup
timeDesign -postRoute -hold -expandedViews -outDir $out/reports/final_hold
# Keep mapped synthesis area separate from the implemented cell footprint.
report_area -depth 1 -detail > $out/reports/13_final_logical_area.rpt
report_area -depth 1 -detail -include_physical > $out/reports/13_final_physical_area.rpt
summaryReport -noHtml -outfile $out/reports/13_final_summary.rpt
set diode_report [open $out/reports/13_antenna_diodes.rpt w]
puts $diode_report "antenna_diodes [llength [dbGet -e top.insts.cell.name ANTENNABWP7T]]"
close $diode_report
source $run_root/scripts/report_implemented_area.tcl
report_implemented_area $out/reports
saveDesign $out/checkpoints/13_padclean.enc
puts FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED
exit
