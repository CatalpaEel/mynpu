# Program EGo1's configuration Flash through its onboard USB-JTAG cable.
# Replaces the existing image at address zero, including the factory demo.
# The external FT232H/J5 probe is used later for the RISC-V Debug Module.
if {[llength $argv] ni {1 2} || [lindex $argv 0] ni {private shared}} {
    error "Expected -tclargs private|shared ?exact_cfgmem_part?"
}
set layout [lindex $argv 0]
set flash_part n25q64-3.3v-spi-x1_x2_x4
if {[llength $argv] == 2} { set flash_part [lindex $argv 1] }
if {![string match *64*3.3v* $flash_part]} {
    error "This image requires a confirmed 64-Mbit, 3.3-V Flash part"
}
set script_dir [file dirname [file normalize [info script]]]
set image [file join $script_dir build ego1_jtag_${layout}_flash.mcs]
if {![file isfile $image]} { error "Generate $image with build_flash.tcl first" }
open_hw_manager
# Vivado 2023.2 embeds Tcl 8.5 (no Tcl 8.6 "try" command).
set failed [catch {
    # Vivado may list the same name for several supported FPGA families.
    # Check exact names and compatibility, without using a wildcard choice.
    set matches [get_cfgmem_parts -quiet $flash_part]
    if {[lsort -unique $matches] ne [list $flash_part]} {
        error "Unknown/ambiguous Flash part: $flash_part; check the board marking"
    }
    set selected_part [lindex $matches 0]
    if {[lsearch -exact [get_property COMPATIBLE_PARTS $selected_part] artix7] < 0 ||
        [get_property MEM_DENSITY $selected_part] != 64} {
        error "Expected an Artix-7 compatible, 64-Mbit Flash part"
    }
    connect_hw_server
    set targets [get_hw_targets]
    if {[llength $targets] != 1} {
        error "Connect only the EGo1 onboard configuration cable; found $targets"
    }
    open_hw_target [lindex $targets 0]
    set devices [get_hw_devices]
    if {[llength $devices] != 1 || ![string match xc7a35t* [lindex $devices 0]]} {
        error "Expected exactly one XC7A35T"
    }
    set device [lindex $devices 0]
    current_hw_device $device
    refresh_hw_device $device
    create_hw_cfgmem -hw_device $device $selected_part
    set memory [get_property PROGRAM.HW_CFGMEM $device]
    set_property PROGRAM.FILES [list $image] $memory
    set_property PROGRAM.ADDRESS_RANGE use_file $memory
    set_property PROGRAM.ERASE 1 $memory
    set_property PROGRAM.BLANK_CHECK 1 $memory
    set_property PROGRAM.CFG_PROGRAM 1 $memory
    set_property PROGRAM.VERIFY 1 $memory
    # Load Vivado's temporary SPI programming bridge into the FPGA.
    set_property PROBES.FILE {} $device
    create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
    program_hw_devices $device
    program_hw_cfgmem $memory
    puts "FLASH_PROGRAM_VERIFY_PASS: $layout, $flash_part, $image"
    puts "Power OFF, select JP2 QSPI per board labels, then power from a USB charger."
    puts "CPU/weights/input are still loaded through external FT232H + OpenOCD, not Flash."
} failure options]
catch {close_hw_target}
catch {disconnect_hw_server}
close_hw_manager
if {$failed} { return -options $options $failure }
