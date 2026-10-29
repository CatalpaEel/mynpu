# Restore one checkpoint in the real GUI and export its current layout canvas.
# Set EDA_GUI_RUN_DIR, EDA_GUI_CHECKPOINT and EDA_GUI_PICTURE in the environment.
source [file join [file dirname [info script]] gui_open.tcl]
set picture [file normalize $env(EDA_GUI_PICTURE)]
file mkdir [file dirname $picture]
if {[info exists env(EDA_GUI_VIEW)]} {setDrawView $env(EDA_GUI_VIEW)}
setLayerPreference flightLine -isVisible 0
setLayerPreference hinst -isVisible 0
setLayerPreference guide -isVisible 0
fit
update idletasks
gui_dump_picture $picture -format PNG -width 1400 -height 1100
puts "FLOW_GUI_PICTURE_READY $picture"
if {[info exists env(EDA_GUI_EXIT_AFTER_CAPTURE)] && $env(EDA_GUI_EXIT_AFTER_CAPTURE) eq "1"} {
    exit
}
