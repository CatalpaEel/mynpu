OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Bank0 physical alias. NPU-owned model/activation regions start at 0x800. */
MEMORY { CODE (rwx) : ORIGIN = 0x80000000, LENGTH = 2K }
__stack_top = 0x80001fc0;
SECTIONS {
  /DISCARD/ : { *(.note*) *(.comment) *(.riscv.attributes) }
  .text : { *(.text.init) *(.text .text.*) } > CODE
  .rodata : { . = ALIGN(4); *(.rodata .rodata.*) } > CODE
  .data : { . = ALIGN(4); *(.data .data.*) } > CODE
  .bss : { . = ALIGN(4); _bss_start = .; *(.bss .bss.*) *(COMMON) . = ALIGN(4); _bss_end = .; } > CODE
  ASSERT(_bss_end <= 0x80000800, "CPU overlaps shared model region")
}
