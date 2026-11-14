# Project RTL only; packages precede modules. Paths relative to npu/rtl.
common/npu_addr_pkg.sv
cnn/npu_stream_pkg.sv
common/npu_rr_select.sv
common/npu_clock_gate.sv
cnn/npu_cnn.sv
cnn/npu_cnn_mac.sv
top/npu_core.sv
interconnect/npu_data_regfile.sv
debug/npu_debug_boot.sv
debug/npu_jtag_debug.sv
matrix/npu_matmul.sv
matrix/npu_matrix_stream.sv
control/npu_mmio.sv
top/npu_soc.sv
cnn/npu_stream.sv
cnn/npu_stream_control.sv
cnn/npu_stream_engine.sv
vector/npu_vector.sv
vector/npu_vector_stream.sv
interconnect/xbar.sv
interconnect/xbar_stream.sv
interconnect/npu_multi_read.sv

quant/npu_shared_quant.sv

common/npu_store_pack.sv
