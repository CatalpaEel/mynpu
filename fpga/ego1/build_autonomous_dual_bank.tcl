# Same two single-port memories as the ASIC. Independent project and artifacts.
set ::AUTONOMOUS_NPU_LANES 4
set ::AUTONOMOUS_DUAL_BANK 1
set ::AUTONOMOUS_MODEL_LAYOUT "dual-bank"
set ::AUTONOMOUS_PROJECT_DIR "vivado_autonomous_dual_bank"
set ::AUTONOMOUS_BUILD_TAG "_dual_bank"
source [file join [file dirname [file normalize [info script]]] build_autonomous_bitstream.tcl]
