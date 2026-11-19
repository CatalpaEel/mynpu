# Match run_fullchip.py defaults when stages are run interactively.
foreach {key value} {
    CHIP_MACRO_PLAN left CHIP_COMPACT_CORE 0
    FLOW_FIX_ROUTE_SETUP 1 FLOW_FIX_ROUTE_HOLD 1
    FLOW_SETUP_MARGIN_NS 0.30 FLOW_OPT_MAX_DENSITY 0.99
} {
    if {![info exists env($key)]} {set env($key) $value}
}
