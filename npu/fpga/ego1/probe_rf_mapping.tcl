# Compare RF-only synthesis with/without a RAM_STYLE XDC override.
# This is an isolated resource probe, not a full SoC or a board build.
# Uses main afb74fd geometry: RF_BANK_WORDS=32, GATHER_PORTS=9, NUM_MASTERS=7.
# vivado -mode batch -source probe_rf_mapping.tcl -tclargs NEW_OUT [STYLE_LIST]
if {$argc < 1 || $argc > 2} {error "Expected NEW_OUT and optional STYLE_LIST"}
set styles {baseline distributed}
if {$argc == 2} {set styles [lindex $argv 1]}
foreach style $styles {
  if {$style ni {baseline distributed rtl_attribute bank_template}} {error "Unknown style $style"}
}
set repo [file normalize [file join [file dirname [info script]] ../../..]]
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Choose a new output directory"}
file mkdir [file join $out src]
set sources {}
foreach name {common/npu_addr_pkg.sv common/npu_rr_select.sv interconnect/npu_data_regfile.sv} {
  set dst [file join $out src [file tail $name]]
  file copy [file join $repo npu rtl $name] $dst
  lappend sources $dst
}
set_param general.maxThreads 4
foreach style $styles {
  set dir [file join $out $style]
  file mkdir $dir
  set xdc [file join $dir rf.xdc]
  set f [open $xdc w]
  puts $f {create_clock -name rf_clock -period 40.000 [get_ports clk_i]}
  puts $f {set_false_path -from [get_ports rst_ni]}
  if {$style eq "distributed"} {
    # XDC accepts synthesis properties; diagnostics/assertions stay in Tcl.
    puts $f {set_property RAM_STYLE distributed [get_cells -hierarchical -filter {NAME =~ *words_reg* && IS_SEQUENTIAL == 1}]}
  }
  close $f
  set variant_sources $sources
  if {$style in {rtl_attribute bank_template}} {
    # Only an isolated source copy changes; the repository RTL remains intact.
    set f [open [lindex $sources 2] r]
    set rtl [read $f]
    close $f
    if {$style eq "rtl_attribute"} {
      set old {(* ram_style="registers" *)}
      if {[string first $old $rtl] < 0} {error "Expected RF RAM_STYLE declaration"}
      set rtl [string map [list $old {(* ram_style="distributed" *)}] $rtl]
    } else {
      # Storage-only prototype: give each bank a local 1R/byte-write RAM.
      # Arbitration and response registers stay untouched. Not production RTL.
      set replacements [list \
        {(* ram_style="registers" *) logic [31:0] words[8][RF_BANK_WORDS/4];} \
        {// Bank storage is declared inside each generate block.} \
        {bank_data[b] = words[b][read_row[b]];} {} \
        {for (genvar b = 0; b < 8; b++) begin : g_bank} \
        {for (genvar b = 0; b < 8; b++) begin : g_bank
    (* ram_style="distributed" *) logic [31:0] bank_mem[RF_BANK_WORDS/4];
    assign bank_data[b] = bank_mem[read_row[b]];} \
        {words[b][write_row[b]][k*8+:8]} {bank_mem[write_row[b]][k*8+:8]}]
      foreach {old new} $replacements {
        if {[string first $old $rtl] < 0} {error "Missing bank-template replacement"}
      }
      set rtl [string map $replacements $rtl]
    }
    set rf_copy [file join $dir npu_data_regfile.sv]
    set f [open $rf_copy w]
    puts -nonewline $f $rtl
    close $f
    set variant_sources [lreplace $sources 2 2 $rf_copy]
  }
  create_project -in_memory -part xc7a35tcsg324-1
  set_property verilog_define {NPU_RF_BANK_WORDS=32} [get_filesets sources_1]
  add_files -norecurse $variant_sources
  add_files -fileset constrs_1 $xdc
  synth_design -top npu_data_regfile -part xc7a35tcsg324-1 -mode out_of_context \
    -generic {GATHER_PORTS=9 NUM_MASTERS=7} -directive AreaOptimized_medium
  report_utilization -file [file join $dir utilization.rpt]
  write_checkpoint -force [file join $dir synthesized.dcp]
  set f [open [file join $dir storage_primitives.txt] w]
  foreach kind {FDRE FDCE RAM32M RAM32X1S RAM32X1D RAM64M RAM64X1S RAM64X1D} {
    puts $f "$kind [llength [get_cells -quiet -hierarchical -filter REF_NAME==$kind]]"
  }
  close $f
  close_project
}
puts "RF_MAPPING_PROBE_COMPLETE $out"
