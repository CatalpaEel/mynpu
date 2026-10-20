# Reuse the routed Lab6 SoC; only the FPGA configuration settings change.
# This script never connects to or writes a physical board.
if {[llength $argv] != 1 || [lindex $argv 0] ni {private shared all}} {
    error "Expected -tclargs private|shared|all"
}
set script_dir [file dirname [file normalize [info script]]]
set out_dir [file join $script_dir build]
set layouts [lindex $argv 0]
if {$layouts eq "all"} { set layouts {private shared} }
set_param general.maxThreads 4
foreach layout $layouts {
    set checkpoint [file join $script_dir vivado_jtag_${layout} \
        ego1_mynpu_jtag.runs impl_1 ego1_soc_top_routed.dcp]
    if {![file isfile $checkpoint]} {
        error "Missing $checkpoint; run build_jtag_${layout}.tcl first"
    }
    open_checkpoint $checkpoint
    if {[get_property PART [current_design]] ne "xc7a35tcsg324-1"} {
        error "Expected EGo1 XC7A35T CSG324 -1"
    }
    # The board's 64-Mbit / 8-MiB, 3.3-V QSPI Flash boots from address zero.
    # A conservative configuration clock is independent of the 50-MHz SoC.
    set_property CFGBVS VCCO [current_design]
    set_property CONFIG_VOLTAGE 3.3 [current_design]
    set_property CONFIG_MODE SPIx4 [current_design]
    set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
    set_property BITSTREAM.CONFIG.CONFIGRATE 6 [current_design]
    set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
    file mkdir $out_dir
    set stem [file join $out_dir ego1_jtag_${layout}_flash]
    write_bitstream -force ${stem}.bit
    foreach format {mcs bin} {
        write_cfgmem -force -format $format -interface SPIx4 -size 8 \
            -loadbit [list up 0x00000000 ${stem}.bit] -file ${stem}.${format}
    }
    puts "FLASH_IMAGE: $layout, SPIx4, 8 MiB, offset 0, CCLK 6 MHz: ${stem}.mcs"
    close_design
}
