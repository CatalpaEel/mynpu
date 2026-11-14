# Explicit hardware action. Run only after connecting the EGo1 configuration USB.
# vivado -mode batch -source program_fpga.tcl -tclargs /absolute/path/ego1_mynpu.bit
if {$argc != 1} {error "Usage: program_fpga.tcl <bitstream>"}
set image [file normalize [lindex $argv 0]]
if {![file isfile $image] || [file extension $image] ne ".bit"} {error "Expected an existing .bit file"}
open_hw_manager
connect_hw_server
open_hw_target
set devices [get_hw_devices -filter {PART =~ xc7a35t*}]
if {[llength $devices] != 1} {error "Expected exactly one XC7A35T; inspect Hardware Manager"}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE $image $device
program_hw_devices $device
refresh_hw_device $device
puts "EGO1 CONFIGURATION PROGRAMMED: $image"
close_hw_manager
