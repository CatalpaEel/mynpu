set bit [file normalize "C:/Users/zhujunan/Desktop/tapeout/mynpu-latest-review-20261111/npu/build/ego1-board-kit-10m-cpurf-dsp-20261114/ego1_mynpu.bit"]
set mcs [file normalize "C:/Users/zhujunan/Desktop/tapeout/mynpu-latest-review-20261111/npu/build/ego1-board-kit-10m-cpurf-dsp-20261114/ego1_mynpu.mcs"]
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] != 1} {error "Expected one onboard configuration target"}
open_hw_target [lindex $targets 0]
set d [lindex [get_hw_devices -filter {PART =~ xc7a35t*}] 0]
if {$d eq ""} {error "XC7A35T not found"}
current_hw_device $d
refresh_hw_device $d
set part [lindex [get_cfgmem_parts n25q64-3.3v-spi-x1_x2_x4] 0]
set cfg [create_hw_cfgmem -hw_device $d -mem_dev $part]
set_property PROGRAM.FILES [list $mcs] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.BLANK_CHECK 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY 1 $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg
set_property PROBES.FILE {} $d
create_hw_bitstream -hw_device $d [get_property PROGRAM.HW_CFGMEM_BITFILE $d]
program_hw_devices $d
puts "Programming and verifying configuration memory..."
program_hw_cfgmem -hw_cfgmem $cfg
puts "FLASH_PROGRAM_VERIFY_PASS: 10MHz current board kit"
close_hw_manager
