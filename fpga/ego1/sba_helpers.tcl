# Exact 32-bit DM SBA transactions, also exercised by the RTL cold-load TB.
proc mynpu_wait_sba {} {
  for {set n 0} {$n<200} {incr n} {
    set s [riscv dmi_read 0x38]
    if {$s & 0x407000} { error [format "SBA error SBCS=0x%08x (reset/reload required)" $s] }
    if {!($s & 0x200000)} { return }
    sleep 1
  }
  error "SBA busy timeout"
}
proc mynpu_write_words {address words} {
  if {$address & 3} { error "Unaligned SBA address" }
  foreach word $words {
    riscv dmi_write 0x38 0x40000
    riscv dmi_write 0x39 $address
    riscv dmi_write 0x3c $word
    mynpu_wait_sba
    incr address 4
  }
  return {}
}
proc mynpu_read_words {address count} {
  if {($address & 3) || $count<1 || $count>4096} { error "Invalid SBA read range" }
  set words {}
  for {set n 0} {$n<$count} {incr n} {
    riscv dmi_write 0x38 0x140000
    riscv dmi_write 0x39 $address
    mynpu_wait_sba
    lappend words [format 0x%08x [riscv dmi_read 0x3c]]
    incr address 4
  }
  return $words
}
proc mynpu_reset {} {
  poll off
  # DM survives ndmreset; Boot RUN, CPU, NPU and bus interfaces are reset.
  riscv dmi_write 0x10 1
  riscv dmi_write 0x38 0x407000
  mynpu_wait_sba
  riscv dmi_write 0x10 3
  sleep 10
  riscv dmi_write 0x10 0x80000001
  sleep 10
  if {!([riscv dmi_read 0x11] & 0x200)} { error "CPU failed to halt in Boot ROM" }
  mynpu_write_words 0x10030 {0}
  return [mynpu_read_words 0x10034 1]
}
proc mynpu_expect {build_id cache_words} {
  if {[lindex [mynpu_read_words 0x10034 1] 0]!=$build_id ||
      [lindex [mynpu_read_words 0x10038 1] 0]!=$cache_words} {
    error "Wrong bitstream/layout/lanes/cache; no image loaded"
  }
  return {}
}
proc mynpu_run {} {
  mynpu_write_words 0x10030 {1}
  riscv dmi_write 0x10 0x40000001
  for {set n 0} {$n<200} {incr n} {
    if {[riscv dmi_read 0x11] & 0x20000} {
      riscv dmi_write 0x10 1
      poll on
      return {}
    }
    sleep 1
  }
  error "CPU resume timeout"
}
