# Adapted from the erase/blank/program/verify sequence used on the EGo1 board.
# Usage: vivado -mode batch -source program_flash.tcl -tclargs /absolute/new.mcs
if {$argc != 1} {error "Expected one MCS path"}
set mcs [file normalize [lindex $argv 0]]
if {![file isfile $mcs]} {error "MCS file not found: $mcs"}
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} {error "Expected one onboard configuration target"}
open_hw_target [lindex $targets 0]
set devices [get_hw_devices -filter {PART =~ xc7a35t*}]
if {[llength $devices] != 1} {error "Expected one XC7A35T device"}
set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device $device
set parts [get_cfgmem_parts n25q64-3.3v-spi-x1_x2_x4]
if {[llength $parts] != 1} {error "EGo1 N25Q64 configuration memory part unavailable"}
set cfg [create_hw_cfgmem -hw_device $device -mem_dev [lindex $parts 0]]
set_property PROGRAM.FILES [list $mcs] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.BLANK_CHECK 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY 1 $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg
set_property PROBES.FILE {} $device
create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
program_hw_devices $device
program_hw_cfgmem -hw_cfgmem $cfg
puts "FLASH_PROGRAM_VERIFY_PASS: $mcs"
close_hw_manager
