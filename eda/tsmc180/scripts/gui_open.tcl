# GUI import or checkpoint restore only. Does not run implementation stages.
if {[dbGet top.name] ni {0x0 {}}} {error "Open a fresh Innovus session before loading this entry."}
set run_root [file normalize $env(EDA_GUI_RUN_DIR)]
set out $run_root/mynpu/pnr
if {[file exists $run_root/scripts/flow_paths.tcl]} {
    source $run_root/scripts/flow_paths.tcl
    set stdroot $pdk/tcb018gbwp7t_290a/TSMCHOME/digital
}
set checkpoint $env(EDA_GUI_CHECKPOINT)
if {$checkpoint eq "init"} {
    source $run_root/scripts/gui_init.tcl
} else {
    if {![regexp {^[A-Za-z0-9_]+$} $checkpoint]} {error "Invalid checkpoint name"}
    set checkpoint_path $run_root/mynpu/pnr/checkpoints/$checkpoint.enc.dat
    if {![file isdirectory $checkpoint_path]} {error "Missing checkpoint: $checkpoint_path"}
    restoreDesign $checkpoint_path mynpu_asic_top
}
set macronames [lsort [dbGet [dbGet top.insts.cell.name RA1SHD_2048x32M8 -p2].name]]
win
fit
puts "GUI ready: [dbGet top.name]; checkpoint=$checkpoint"
