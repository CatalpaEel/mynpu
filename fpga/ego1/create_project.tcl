# Create a reproducible Vivado project for the EGo1 board.
# Usage from Vivado Tcl Console:
#   cd <repo>/fpga/ego1
#   source create_project.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file normalize [file join $script_dir vivado]]
set project_name ego1_mynpu
set part_name xc7a35tcsg324-1

if {[llength [get_projects -quiet]] > 0} {
    close_project
}
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
lappend rtl_files [file normalize [file join $script_dir ego1_soc_top.sv]]
add_files -norecurse -fileset $source_set $rtl_files
set_property include_dirs $include_dirs $source_set

set xdc_file [file normalize [file join $script_dir ego1.xdc]]
add_files -norecurse -fileset $constr_set $xdc_file

# Make the firmware path explicit for synthesis. Copying it into the project
# also makes the generated project self-contained for Vivado runs.
set hex_src [file normalize [file join $repo_root generated 8k cpu.hex]]
set hex_dst_dir [file join $project_dir generated 8k]
file mkdir $hex_dst_dir
file copy -force $hex_src [file join $hex_dst_dir cpu.hex]
add_files -norecurse -fileset $source_set $hex_src
set_property generic "CPU_INIT_FILE=\"$hex_src\"" $source_set

set_property top ego1_soc_top $source_set
set_property top_auto_set 0 $source_set
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
update_compile_order -fileset $source_set
puts "EGo1 project created: [file join $project_dir $project_name.xpr]"
puts "Top: ego1_soc_top, part: $part_name, system clock: 50 MHz MMCM"

