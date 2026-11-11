# Explicit board-only action: run from repository root after loading the bitstream.
# openocd -f npu/fpga/ego1/ft232h.cfg -f npu/debug/target.cfg \
#         -f npu/fpga/ego1/load_mnist.tcl
init
# Stop a previous run and return the CPU to its bootstrap, then halt it.
mww 0x40000008 0
halt
# Contiguous 16 KiB image: xbar maps it onto the two 8 KiB SRAM banks.
load_image npu/mnist/artifacts/sram0.bin 0x80000000 bin
verify_image npu/mnist/artifacts/sram0.bin 0x80000000 bin
mww 0x4000000c 0x80000080
mww 0x40000008 1
resume
set result 0
for {set i 0} {$i < 200} {incr i} {
  set result [lindex [read_memory 0x40000004 32 1] 0]
  if {$result != 0} {break}
  sleep 10
}
if {$result != 0x600d0001} {error [format "MNIST failed/timeout: 0x%08x" $result]}
set f [open npu/mnist/artifacts/gold0_5.hex r]
set gold [regexp -all -inline {\S+} [read $f]]
close $f
set words [read_memory 0x80001400 32 3]
for {set j 0} {$j < 10} {incr j} {
  set got [expr {([lindex $words [expr {$j/4}]] >> (($j%4)*8)) & 255}]
  scan [lindex $gold $j] %x want
  if {$got != $want} {error "Logit $j: got $got expected $want"}
}
puts "EGO1 MNIST PASS: ten integer logits match"
# Keep OpenOCD available for interactive debugging; do not automatically reprogram.
