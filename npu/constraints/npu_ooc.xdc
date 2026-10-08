# Logical timing target for an OOC implementation; no board pin assignments.
create_clock -name sys_clk -period 20.000 [get_ports clk_i]
set_input_delay -clock sys_clk 2.000 [get_ports {cpu_run_i host_req_i host_we_i host_be_i[*] host_addr_i[*] host_wdata_i[*] dma_rx_valid_i dma_rx_data_i[*] dma_rx_keep_i[*] dma_rx_last_i dma_tx_ready_i}]
set_output_delay -clock sys_clk 2.000 [all_outputs]
set_false_path -from [get_ports rst_ni]
