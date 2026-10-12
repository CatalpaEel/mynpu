# Create the EGo1 project that does not expose Debug Module pins.
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file normalize [file join $script_dir vivado_autonomous]]
set project_name ego1_mynpu_autonomous
set part_name xc7a35tcsg324-1

if {[llength [get_projects -quiet]] > 0} { close_project }
create_project -force $project_name $project_dir -part $part_name
set source_set [get_filesets sources_1]
set constr_set [get_filesets constrs_1]

set rtl_files {}
set include_dirs {}
set fh [open [file join $repo_root sim soc.f] r]
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match {#*} $line]} { continue }
    if {[string match {+incdir+*} $line]} {
        lappend include_dirs [file normalize [file join $repo_root [string range $line 8 end]]]
    } else {
        lappend rtl_files [file normalize [file join $repo_root $line]]
    }
}
close $fh
lappend rtl_files [file normalize [file join $script_dir ego1_autonomous_top.sv]]
add_files -norecurse -fileset $source_set $rtl_files
set_property include_dirs $include_dirs $source_set

set xdc_file [file normalize [file join $script_dir ego1_autonomous.xdc]]
add_files -norecurse -fileset $constr_set $xdc_file
set hex_src [file normalize [file join $repo_root generated 8k cpu.hex]]
add_files -norecurse -fileset $source_set $hex_src
if {[info exists ::AUTONOMOUS_NPU_LANES]} {
  set npu_lanes $::AUTONOMOUS_NPU_LANES
} else {
  set npu_lanes 1
}
set_property generic "CPU_INIT_FILE=\"$hex_src\" NPU_LANES=$npu_lanes" $source_set
set_property top ego1_autonomous_top $source_set
set_property top_auto_set 0 $source_set
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
# VIO observes the CPU self-test result and offers a USB-controlled reset.
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_autonomous
set_property -dict [list CONFIG.C_NUM_PROBE_IN {6} CONFIG.C_NUM_PROBE_OUT {1} \
    CONFIG.C_PROBE_IN0_WIDTH {32} CONFIG.C_PROBE_IN1_WIDTH {32} \
    CONFIG.C_PROBE_IN2_WIDTH {4} CONFIG.C_PROBE_IN3_WIDTH {32} \
    CONFIG.C_PROBE_IN4_WIDTH {32} CONFIG.C_PROBE_IN5_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT0_INIT_VAL {0x0}] [get_ips vio_autonomous]
generate_target all [get_ips vio_autonomous]
update_compile_order -fileset $source_set
puts "EGo1 autonomous project created: [file join $project_dir $project_name.xpr]"
