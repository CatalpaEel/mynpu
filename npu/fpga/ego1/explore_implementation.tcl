# Reuse a frozen synthesis checkpoint to compare implementation area directives.
# No RTL edits, frequency changes, resource-DRC overrides, or device changes.
# vivado -mode batch -source explore_implementation.tcl -tclargs SYNTH_BUILD NEW_OUT [DIRECTIVE_LIST]
if {$argc < 2 || $argc > 3} {error "Expected SYNTH_BUILD NEW_OUT and optional DIRECTIVE_LIST"}
set directives {ExploreWithRemap ExploreSequentialArea}
if {$argc == 3} {set directives [lindex $argv 2]}
foreach d $directives {
  if {$d ni {ExploreWithRemap ExploreSequentialArea ResynthRemap AreaThenResynthRemap}} {
    error "Unknown directive $d"
  }
}
set synth_build [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set checkpoint [file join $synth_build project ego1_mynpu.runs synth_1 ego1_soc_top.dcp]
if {![file isfile $checkpoint]} {error "Missing synthesis checkpoint: $checkpoint"}
if {[file exists $out]} {error "Choose a new output directory"}
file mkdir $out
file copy $checkpoint [file join $out input_synth.dcp]
file copy [file join $synth_build source_manifest.json] [file join $out source_manifest.json]
set_param general.maxThreads 8
set any_pass 0
foreach directive $directives {
  set variant [file join $out $directive]
  file mkdir $variant
  set stage open_checkpoint
  set rc [catch {
    open_checkpoint [file join $out input_synth.dcp]
    if {[get_property PART [current_design]] ne "xc7a35tcsg324-1"} {
      error "Unexpected FPGA part"
    }
    set stage opt_design
    if {$directive eq "ResynthRemap"} {
      opt_design
      opt_design -resynth_remap
    } elseif {$directive eq "AreaThenResynthRemap"} {
      opt_design -directive ExploreArea
      opt_design -resynth_remap
    } else {
      opt_design -directive $directive
    }
    report_utilization -file [file join $variant utilization_opt.rpt]
    report_utilization -hierarchical -file [file join $variant utilization_opt_hierarchy.rpt]
    report_timing_summary -file [file join $variant timing_opt.rpt]
    write_checkpoint -force [file join $variant optimized.dcp]
    set stage place_design
    # Vivado must accept capacity DRC before placement; never override it.
    place_design
    report_utilization -file [file join $variant utilization_placed.rpt]
    set stage route_design
    route_design
    write_checkpoint -force [file join $variant routed.dcp]
    report_utilization -file [file join $variant utilization_routed.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained -file [file join $variant timing_routed.rpt]
    report_drc -file [file join $variant drc.rpt]
    report_cdc -details -file [file join $variant cdc.rpt]
    report_route_status -file [file join $variant route_status.rpt]
    check_timing -verbose -file [file join $variant check_timing.rpt]
    set stage final_checks
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    if {![llength $setup] || ![llength $hold]} {error "No timed paths"}
    if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {
      error "Setup or hold timing failed"
    }
    set violations [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
    if {[llength $violations]} {error "Unresolved DRC: $violations"}
    set stage write_bitstream
    write_bitstream -force [file join $variant ego1_mynpu.bit]
    write_cfgmem -force -format mcs -interface SPIx4 -size 8 \
      -loadbit [list up 0x0 [file join $variant ego1_mynpu.bit]] \
      -file [file join $variant ego1_mynpu.mcs]
    set f [open [file join $variant implementation_pass.txt] w]
    puts $f "Vivado [version -short]; xc7a35tcsg324-1; $directive"
    puts $f "setup_slack_ns=[get_property SLACK $setup]"
    puts $f "hold_slack_ns=[get_property SLACK $hold]"
    close $f
    set any_pass 1
  } detail]
  set f [open [file join $variant result.txt] w]
  puts $f "directive=$directive"
  puts $f "passed=[expr {!$rc}]"
  puts $f "last_stage=$stage"
  if {$rc} {puts $f "error=$detail"}
  close $f
  puts "AREA_VARIANT $directive passed=[expr {!$rc}] stage=$stage"
  catch {close_design}
}
if {!$any_pass} {error "Neither implementation directive produced a passing bitstream"}
