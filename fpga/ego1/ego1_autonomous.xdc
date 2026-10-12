# EGo1 autonomous/no-Debug top-level constraints.
set_property PACKAGE_PIN P17 [get_ports fpga_clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_clk_i]
create_clock -name fpga_clk_100m -period 10.000 [get_ports fpga_clk_i]

# Active-low user reset button.
set_property PACKAGE_PIN P15 [get_ports rst_ni]
set_property IOSTANDARD LVCMOS33 [get_ports rst_ni]

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

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
