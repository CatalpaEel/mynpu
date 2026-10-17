# Tcl command/timeout checks without USB hardware. Not a substitute for RTL/board.
set memory [dict create 65584 0 65588 0x4a541004 65592 0]
set sbcs 0
set address 0
set dmstatus 0x200
set forced 0
proc sleep {n} {}
proc poll {state} {}
proc riscv {op reg args} {
  global memory sbcs address dmstatus forced
  if {$op eq "dmi_read"} {
    if {$reg==0x38} { return $forced }
    if {$reg==0x11} { return $dmstatus }
    if {$reg==0x3c} { return [dict get $memory $address] }
    error "Unexpected register"
  }
  set v [lindex $args 0]
  if {$reg==0x38} { set sbcs $v }
  if {$reg==0x39} { set address [expr {$v+0}] }
  if {$reg==0x3c} { dict set memory $address $v }
  if {$reg==0x10} {
    if {$v==3} { dict set memory 65584 0 }
    if {$v==0x80000001} { set dmstatus 0x200 }
    if {$v==0x40000001} { set dmstatus 0x20000 }
  }
}
source fpga/ego1/sba_helpers.tcl
if {[mynpu_reset] ne "0x4a541004"} { error "Reset ID failed" }
mynpu_expect 0x4a541004 0
if {![catch {mynpu_expect 0x4a541104 1}]} { error "Wrong layout was accepted" }
mynpu_write_words 0x80000000 {0x12345678 0xffffffff 0}
set values [mynpu_read_words 0x80000000 3]
if {$values ne "0x12345678 0xffffffff 0x00000000"} { error "Word IO failed: $values" }
mynpu_run
if {[dict get $memory 65584]!=1} { error "RUN release failed" }
set forced 0x400000
if {![catch {mynpu_read_words 0x80000000 1} msg] || ![string match {*SBA error*} $msg]} { error "SBA error not detected" }
set forced 0x200000
if {![catch {mynpu_read_words 0x80000000 1} msg] || ![string match {*timeout*} $msg]} { error "SBA timeout not detected" }
puts "SBA TCL PASS: reset/run, word IO, sticky error and busy timeout"
