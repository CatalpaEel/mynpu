# Functional (not LVS) netlist after native signal PAD insertion. No DB edits.
if {[catch {
    set run_root [file normalize [file join [file dirname [info script]] ..]]
    set out $run_root/mynpu/pnr
    restoreDesign $out/checkpoints/03_io_floorplan.enc.dat mynpu_asic_top
    set excludes {PCORNER PFILLER20 PFILLER10 PFILLER5 PFILLER1 PFILLER05 PFILLER0005 PRCUT PAD60LU_OBV PVDD1CDG PVSS1CDG PVDD2CDG PVSS2CDG PVDD2POC}
    saveNetlist $out/outputs/io_connected_functional.v -excludeLeafCell -topModuleFirst -removePowerGround -excludeCellInst $excludes
    puts GPIO_IO_FUNCTIONAL_EXPORT_PASS
} message options]} {
    puts stderr "$message\n[dict get $options -errorinfo]"
    exit 1
}
exit 0
