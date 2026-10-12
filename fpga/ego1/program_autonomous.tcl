# List the connected FPGA, or program its volatile configuration SRAM.
# Usage: vivado -mode batch -source fpga/ego1/program_autonomous.tcl
#        vivado -mode batch -source fpga/ego1/program_autonomous.tcl -tclargs --program 3
#        vivado -mode batch -source fpga/ego1/program_autonomous.tcl -tclargs --program 3 8lane
set script_dir [file dirname [file normalize [info script]]]
set do_program 0
set reset_rounds 3
set build_tag ""
if {[llength $argv] >= 1 && [lindex $argv 0] eq "--program" && [llength $argv] <= 3} {
    set do_program 1
    if {[llength $argv] == 2} { set reset_rounds [lindex $argv 1] }
    if {[llength $argv] == 3} {
        set reset_rounds [lindex $argv 1]
        set build_tag "_[lindex $argv 2]"
    }
    if {![string is integer -strict $reset_rounds] || $reset_rounds < 0 || $reset_rounds > 1000} {
        error "Reset rounds must be an integer from 0 to 1000"
    }
} elseif {[llength $argv] != 0} {
    error "Expected no arguments (detect only) or --program ?reset_rounds? ?tag?"
}

proc named_probe {vio pattern} {
    set matches {}
    foreach probe [get_hw_probes -of_objects $vio] {
        if {[string match $pattern [get_property NAME $probe]]} { lappend matches $probe }
    }
    if {[llength $matches] != 1} { error "Expected one VIO probe matching $pattern: $matches" }
    return [lindex $matches 0]
}
proc probe_int {probe} {
    set raw [get_property INPUT_VALUE $probe]
    regsub -nocase {^0x} $raw {} raw
    if {[scan $raw %x value] != 1} { error "Invalid VIO value: $raw" }
    return $value
}
proc probe_hex {probe} {
    set raw [string tolower [get_property INPUT_VALUE $probe]]
    regsub -nocase {^0x} $raw {} raw
    return [format %08s $raw]
}
proc check_selftest {vio status_probe error_probe irq_probe result_probe cycle_probe timeout_probe round} {
    set deadline [expr {[clock milliseconds] + 10000}]
    while {[clock milliseconds] < $deadline} {
        refresh_hw_vio $vio
        set status_hex [probe_hex $status_probe]
        set status [probe_int $status_probe]
        set code [probe_int $error_probe]
        set timeout [probe_int $timeout_probe]
        if {$status == 0xdeadbeef || $timeout != 0} {
            error [format "BOARD_SELFTEST FAIL round=%d status=%08x error=%08x timeout=%d" $round $status $code $timeout]
        }
        if {$status_hex eq "c0dec0de"} {
            set irqs [probe_int $irq_probe]
            set result [probe_int $result_probe]
            set cycles [probe_int $cycle_probe]
            if {$irqs != 4 || $result != 2 || $code != 0 || $cycles == 0} {
                error "Board completed with unexpected IRQ count/result/error/cycles: $irqs/$result/$code/$cycles"
            }
            puts [format "BOARD_SELFTEST PASS round=%d status=%08x irq_edges=%d class=%d cycles=%d" $round $status $irqs $result $cycles]
            return
        }
        after 100
    }
    error [format "Board self-test timed out, last status=%08x" $status]
}
open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets]
puts "FPGA_TARGETS: $targets"
if {[llength $targets] != 1} {
    error "Expected one connected board; found [llength $targets] targets"
}
open_hw_target [lindex $targets 0]
set devices [get_hw_devices]
puts "FPGA_DEVICES: $devices"
if {[llength $devices] != 1 || ![string match "xc7a35t*" [lindex $devices 0]]} {
    error "Expected one XC7A35T FPGA; no device was programmed"
}
set device [lindex $devices 0]
refresh_hw_device $device
if {$do_program} {
    set bit_file [file normalize [file join $script_dir build ego1_autonomous_top${build_tag}.bit]]
    set ltx_file [file normalize [file join $script_dir build ego1_autonomous_top${build_tag}.ltx]]
    if {![file exists $bit_file] || ![file exists $ltx_file]} { error "Build the autonomous bitstream and probes first" }
    set_property PROBES.FILE $ltx_file $device
    set_property PROGRAM.FILE $bit_file $device
    program_hw_devices $device
    refresh_hw_device $device
    puts "AUTONOMOUS_PROGRAMMED: $bit_file"
    set vios [get_hw_vios -of_objects $device]
    if {[llength $vios] != 1} { error "Expected one autonomous VIO core: $vios" }
    set vio [lindex $vios 0]
    set status_probe [named_probe $vio *firmware_status*]
    set error_probe [named_probe $vio *firmware_error*]
    set irq_probe [named_probe $vio *irq_count_q*]
    set result_probe [named_probe $vio *firmware_result*]
    set cycle_probe [named_probe $vio *firmware_cycles*]
    set timeout_probe [named_probe $vio *timeout_q*]
    set reset_probe [named_probe $vio *soft_reset*]
    check_selftest $vio $status_probe $error_probe $irq_probe $result_probe $cycle_probe $timeout_probe 0
    for {set round 1} {$round <= $reset_rounds} {incr round} {
        set_property OUTPUT_VALUE 1 $reset_probe
        commit_hw_vio $vio
        after 100
        refresh_hw_vio $vio
        if {[probe_int $status_probe] != 0 || [probe_int $irq_probe] != 0} {
            error "SoC mailbox/IRQ observer did not clear during USB-controlled reset"
        }
        set_property OUTPUT_VALUE 0 $reset_probe
        commit_hw_vio $vio
        check_selftest $vio $status_probe $error_probe $irq_probe $result_probe $cycle_probe $timeout_probe $round
    }
    puts "BOARD_REGRESSION PASS boots=[expr {$reset_rounds + 1}] inferences=[expr {5 * ($reset_rounds + 1)}]"
}
close_hw_target
disconnect_hw_server
close_hw_manager
