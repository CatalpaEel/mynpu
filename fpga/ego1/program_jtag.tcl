# Configure FPGA only. CPU inference uses the separate FT232H/J5 Lab6 chain.
if {[llength $argv]!=1 || [lindex $argv 0] ni {private shared}} { error "Expected -tclargs private|shared" }
set layout [lindex $argv 0]
set script_dir [file dirname [file normalize [info script]]]
set bit_file [file join $script_dir build ego1_jtag_${layout}.bit]
if {![file exists $bit_file]} { error "Build $bit_file first" }
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets]!=1} { error "Expected exactly one EGo1 configuration cable; found $targets" }
open_hw_target [lindex $targets 0]
set devices [get_hw_devices]
if {[llength $devices]!=1 || ![string match xc7a35t* [lindex $devices 0]]} { error "Expected one XC7A35T" }
set device [lindex $devices 0]
set_property PROBES.FILE {} $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
puts "JTAG_CONFIGURED: $layout; CPU waits in ROM. Connect FT232H and start OpenOCD."
close_hw_target
disconnect_hw_server
close_hw_manager
