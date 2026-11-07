# Actual Innovus canvas from a named checkpoint; use a working DISPLAY.
if {[catch {
    set run_root [file normalize [file join [file dirname [info script]] ..]]
    set out $run_root/mynpu/pnr
    restoreDesign $out/checkpoints/$env(CHIP_CHECKPOINT).enc.dat mynpu_asic_top
    setLayerPreference flightLine -isVisible 0
    setLayerPreference hinst -isVisible 0
    setLayerPreference guide -isVisible 0
    fit
    update idletasks
    gui_dump_picture $env(CHIP_PICTURE) -format PNG -width 1400 -height 1100
    puts "CHIP_PICTURE_COMPLETED $env(CHIP_PICTURE)"
} message options]} {
    puts stderr "CHIP_PICTURE_FAILED $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
