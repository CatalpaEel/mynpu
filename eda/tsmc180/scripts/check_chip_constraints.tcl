set run_root [file normalize [file join [file dirname [info script]] ..]]
set out $run_root/mynpu/chip_synth
source $out/optimized_root.tcl
read_db $out/optimized.genus.db
check_timing_intent -verbose > $out/timing_intent.rpt
report_timing -lint > $out/timing_lint.rpt
puts FLOW_STAGE_OK_CHIP_CONSTRAINT_AUDIT
exit
