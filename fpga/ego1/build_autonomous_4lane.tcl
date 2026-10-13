# True vector-MAC version using the same 2048x32 single-port memory contract
# as the ASIC macro. Separate project directory preserves the 1-lane build.
set ::AUTONOMOUS_NPU_LANES 4
set ::AUTONOMOUS_MODEL_LAYOUT "8k-p4"
set ::AUTONOMOUS_PROJECT_DIR "vivado_autonomous_4lane"
set ::AUTONOMOUS_BUILD_TAG "_4lane"
source [file join [file dirname [file normalize [info script]]] build_autonomous_bitstream.tcl]
