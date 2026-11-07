# Launch with a working DISPLAY, PNR_CHECKPOINT and PNR_PICTURE.
if {[catch {
    source [file join [file dirname [info script]] paths.tcl]
    restoreDesign $out/checkpoints/$env(PNR_CHECKPOINT).enc.dat npu_asic_top
    if {[info exists env(PNR_VIEW)]} {setDrawView $env(PNR_VIEW)}
    setLayerPreference flightLine -isVisible 0
    setLayerPreference hinst -isVisible 0
    setLayerPreference guide -isVisible 0
    fit
    update idletasks
    gui_dump_picture $env(PNR_PICTURE) -format PNG -width 1400 -height 1100
    puts "PNR_PICTURE_COMPLETED $env(PNR_PICTURE)"
} message options]} {
    puts stderr "PNR_PICTURE_FAILED $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
