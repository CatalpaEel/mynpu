# EGo1 V2.2 / XC7A35T-1CSG324C reference constraints.
# Preserves the previously used EGo1 pinout; external DTM is on J5.

set_property PACKAGE_PIN P17 [get_ports fpga_clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_clk_i]
create_clock -name fpga_clk_100m -period 10.000 [get_ports fpga_clk_i]
create_clock -name tck_clock -period 1000.000 [get_ports tck_i]

# P15 is the dedicated RST/S6 input. Lab 6 treats rst_ni as low-active.
set_property PACKAGE_PIN P15 [get_ports rst_ni]
set_property IOSTANDARD LVCMOS33 [get_ports rst_ni]

# Lab 6 external RISC-V Debug Module JTAG on J5.
set_property PACKAGE_PIN E15 [get_ports tck_i]
set_property PACKAGE_PIN E16 [get_ports td_i]
set_property PACKAGE_PIN D15 [get_ports td_o]
set_property PACKAGE_PIN C15 [get_ports tms_i]
set_property IOSTANDARD LVCMOS33 [get_ports {tck_i td_i td_o tms_i}]

# EGo1 user LEDs, active high.
set_property PACKAGE_PIN K3 [get_ports {led_o[0]}]
set_property PACKAGE_PIN M1 [get_ports {led_o[1]}]
set_property PACKAGE_PIN L1 [get_ports {led_o[2]}]
set_property PACKAGE_PIN K6 [get_ports {led_o[3]}]
set_property PACKAGE_PIN J5 [get_ports {led_o[4]}]
set_property PACKAGE_PIN H5 [get_ports {led_o[5]}]
set_property PACKAGE_PIN H6 [get_ports {led_o[6]}]
set_property PACKAGE_PIN K1 [get_ports {led_o[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[*]}]

# tck_i is asynchronous to the MMCM-generated system clock. The Debug Module
# contains its own DMI CDC synchronizers.
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks fpga_clk_100m] \
  -group [get_clocks tck_clock]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# External JTAG timing budget (1 MHz ceiling; start OpenOCD at 10 kHz).
set_input_delay -clock tck_clock -max 100 [get_ports {tms_i td_i}]
set_input_delay -clock tck_clock -min 0 [get_ports {tms_i td_i}]
set_output_delay -clock tck_clock -max 100 [get_ports td_o]
set_output_delay -clock tck_clock -min 0 [get_ports td_o]
# Human-visible indicators have no external synchronous receiver.
set_false_path -to [get_ports {led_o[*]}]
# Board reset is asynchronous; release is synchronized separately in each domain.
set_false_path -from [get_ports rst_ni]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
