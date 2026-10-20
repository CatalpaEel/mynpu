# Fault checks for a persistent Flash write. No hardware APIs are invoked.
# Run in Vivado 2023.2's Tcl 8.5 or ordinary tclsh from the repository root.
set script [file normalize fpga/ego1/program_flash.tcl]
set fixtures {
    set messages {}
    set opened 0
    set closed 0
    set writes 0
    proc puts {message} { lappend ::messages $message }
    proc open_hw_manager {} { set ::opened 1 }
    proc close_hw_manager {} { set ::closed 1 }
    proc get_cfgmem_parts {args} {
        if {$::mode eq "unknown"} { return {} }
        return {n25q64-3.3v-spi-x1_x2_x4 n25q64-3.3v-spi-x1_x2_x4}
    }
    proc get_property {name object} {
        switch -- $name {
            COMPATIBLE_PARTS {
                if {$::mode eq "incompatible"} { return {kintex7} }
                return {- artix7 kintex7}
            }
            MEM_DENSITY { return 64 }
            PROGRAM.HW_CFGMEM { return flash0 }
            PROGRAM.HW_CFGMEM_BITFILE { return vivado_spi_bridge.bit }
            default { error "Unknown test property: $name" }
        }
    }
    proc connect_hw_server {} {}
    proc disconnect_hw_server {} {}
    proc get_hw_targets {} {
        switch -- $::mode {
            disconnected { return {} }
            multiple { return {board0 board1} }
            default { return {board0} }
        }
    }
    proc open_hw_target {target} {}
    proc close_hw_target {} {}
    proc get_hw_devices {} {
        if {$::mode eq "wrong_fpga"} { return xc7a100t_0 }
        return xc7a35t_0
    }
    proc current_hw_device {device} {}
    proc refresh_hw_device {device} {}
    proc create_hw_cfgmem {args} {}
    proc set_property {name value object} { dict set ::properties $name $value }
    proc create_hw_bitstream {args} {}
    proc program_hw_devices {device} {
        if {$::mode eq "bridge_failure"} { error "SPI bridge download failed" }
    }
    proc program_hw_cfgmem {memory} {
        if {$memory ne "flash0"} { error "Expected positional cfgmem object" }
        incr ::writes
        if {$::mode eq "write_failure"} { error "Flash program/verify failed" }
    }
}
set count 0
foreach mode {private shared unknown incompatible disconnected multiple wrong_fpga bridge_failure write_failure invalid_layout} {
    set child [interp create]
    interp eval $child $fixtures
    interp eval $child [list set mode $mode]
    set layout shared
    if {$mode in {private invalid_layout}} { set layout $mode }
    interp eval $child [list set argv [list $layout]]
    set failed [catch {interp eval $child [list source $script]} result]
    set success [expr {$mode in {private shared}}]
    set writes [interp eval $child {set writes}]
    set messages [interp eval $child {join $messages \n}]
    set announced [string match *FLASH_PROGRAM_VERIFY_PASS:* $messages]
    if {$failed == $success || $announced != $success} {
        error "$mode: wrong failure/success reporting: $result / $messages"
    }
    set expected_writes [expr {$success || $mode eq "write_failure"}]
    if {$writes != $expected_writes} { error "$mode: unexpected Flash writes ($writes)" }
    if {[interp eval $child {expr {$opened && !$closed}}]} {
        error "$mode: Hardware Manager not closed after failure"
    }
    interp delete $child
    incr count
}
puts "FLASH_SCRIPT_PASS: $count success/fault scenarios; no physical board access"
