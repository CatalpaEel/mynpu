set parts [get_cfgmem_parts n25q64-3.3v-spi-x1_x2_x4]
puts "PART_COUNT=[llength $parts]"
foreach p $parts {puts "PART=$p"}
