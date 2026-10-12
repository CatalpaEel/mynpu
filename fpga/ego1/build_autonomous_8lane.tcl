# Build the parameterized 8-lane configuration for comparison. The current
# FPGA/ASIC single-port backend serializes memory requests, so this experiment
# is expected to be functionally identical to the 1-lane bitstream until the
# NPU memory is banked or weight-cached.
set ::AUTONOMOUS_NPU_LANES 8
set ::AUTONOMOUS_BUILD_TAG "_8lane"
source [file join [file dirname [file normalize [info script]]] build_autonomous_bitstream.tcl]
