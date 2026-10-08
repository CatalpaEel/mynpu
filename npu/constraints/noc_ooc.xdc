# Logical two-VN flit interfaces, not a board pinout or DDR timing constraint.
create_clock -name sys_clk -period 20.000 [get_ports clk_i]
set_input_delay -clock sys_clk 2.000 [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
set_output_delay -clock sys_clk 2.000 [all_outputs]
set_false_path -from [get_ports rst_ni]
# Board straps / boot-time configuration: stable before reset is released and
# throughout active traffic. They are not per-cycle data/control inputs.
set_false_path -from [get_ports {node_x_i[*] node_y_i[*] port_enable_i[*] mesh_width_i[*] mesh_height_i[*] ddr_present_i}]
