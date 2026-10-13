# Legacy-image comparison with the new 8-lane core. Weight reads use the
# compatibility OIHW prefetch path. For the recommended packed4 configuration,
# use build_autonomous_4lane.tcl and its matching CPU image instead.
set ::AUTONOMOUS_NPU_LANES 8
set ::AUTONOMOUS_BUILD_TAG "_8lane"
source [file join [file dirname [file normalize [info script]]] build_autonomous_bitstream.tcl]
