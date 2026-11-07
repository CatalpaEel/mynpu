# A Tcl error must terminate a noninteractive job rather than leave Innovus
# waiting at its prompt with /dev/null as stdin.
if {![info exists env(FLOW_STAGE_SCRIPT)]} {error "FLOW_STAGE_SCRIPT is required"}
if {[catch {source $env(FLOW_STAGE_SCRIPT)} message options]} {
    puts stderr "**ERROR: Batch stage failed: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
exit 0
