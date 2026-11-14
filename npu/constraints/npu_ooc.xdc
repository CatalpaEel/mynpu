# Logical timing target for an OOC implementation; no board pin assignments.
create_clock -name sys_clk -period 20.000 [get_ports clk_i]
set_input_delay -clock sys_clk 2.000 [get_ports {cpu_run_i gpio_i[*]}]
set_output_delay -clock sys_clk 2.000 [all_outputs]
set_false_path -from [get_ports rst_ni]
