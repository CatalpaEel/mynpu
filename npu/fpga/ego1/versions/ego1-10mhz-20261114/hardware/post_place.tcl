set_param drc.disableLUTOverUtilError 0
set report_dir [file join [file dirname [info script]] reports]
report_utilization -file [file join $report_dir utilization_placed.rpt]
report_drc -file [file join $report_dir drc_placed_default.rpt]
set errors [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
if {[llength $errors]} {error "Post-placement DEFAULT DRC failed: $errors"}
puts "POST_PLACEMENT_DEFAULT_DRC_PASS; LUT capacity check restored"
