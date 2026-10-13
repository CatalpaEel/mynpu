# Standalone structural synthesis check, separate from whole-SoC bitstreams.
set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ../..]]
set out [file join $root build npu4-synth]
file mkdir $out
read_verilog -sv [file join $root rtl mynpu_sram_2048x32_fpga.sv]
read_verilog -sv [file join $root cnn_npu_int8 rtl cnn_npu_lane_mac.sv]
read_verilog -sv [file join $root cnn_npu_int8 rtl cnn_npu_sp_lanes.sv]
synth_design -top cnn_npu_sp_lanes -part xc7a35tcsg324-1 -mode out_of_context -generic LANES=4 -generic MEM_BACKEND=1
report_utilization -file [file join $out utilization.rpt]
write_checkpoint -force [file join $out npu4.dcp]
set multipliers [get_cells -hier -filter {REF_NAME == DSP48E1}]
puts "NPU4_SYNTH_DSP_CELLS: $multipliers"
puts "NPU4_SYNTH_BRAMS: [get_cells -hier -filter {REF_NAME =~ RAMB*}]"
set lanes [get_cells -hier -filter {ORIG_REF_NAME == cnn_npu_lane_mac || REF_NAME == cnn_npu_lane_mac}]
if {[llength $lanes]!=4} {error "Expected 4 independent MAC lane instances: $lanes"}
puts "NPU4_SYNTH_MAC_LANES: $lanes"
