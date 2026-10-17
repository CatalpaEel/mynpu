# Lab6 external FT232H/J5 -> RISC-V DM project. No BRAM firmware preload.
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::JTAG_LAYOUT]} { set ::JTAG_LAYOUT private }
if {$::JTAG_LAYOUT ni {private shared}} { error "JTAG_LAYOUT must be private or shared" }
if {![info exists ::JTAG_NPU_LANES]} { set ::JTAG_NPU_LANES 4 }
if {![info exists ::JTAG_CACHE_WORDS]} { set ::JTAG_CACHE_WORDS 1 }
set project_dir [file join $script_dir vivado_jtag_$::JTAG_LAYOUT]
set project_name ego1_mynpu_jtag
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
  } else { lappend rtl_files [file normalize [file join $repo_root $line]] }
}
close $fh
lappend rtl_files [file join $script_dir ego1_soc_top.sv]
add_files -norecurse -fileset $source_set $rtl_files
set_property include_dirs $include_dirs $source_set
add_files -norecurse -fileset $constr_set [file join $script_dir ego1.xdc]
set shared [expr {$::JTAG_LAYOUT eq "shared"}]
set_property generic "NPU_LANES=$::JTAG_NPU_LANES DUAL_BANK_SHARED=$shared NPU_ACT_CACHE_WORDS=$::JTAG_CACHE_WORDS JTAG_BOOT_CONTROL=1" $source_set
set_property top ego1_soc_top $source_set
set_property top_auto_set 0 $source_set
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
update_compile_order -fileset $source_set
puts "JTAG_PROJECT: $project_dir/$project_name.xpr, $::JTAG_LAYOUT, lanes=$::JTAG_NPU_LANES, CPU waits in Boot ROM"
