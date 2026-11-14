# FPGA-only mapping: no arithmetic, latency, shape, or ASIC RTL changes.
set_property USE_DSP yes [get_cells {i_soc/i_core/i_cnn/i_mac}]
