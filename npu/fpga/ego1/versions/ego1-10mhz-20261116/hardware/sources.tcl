set npu_defines {NPU_RF_BANK_WORDS=32 NPU_MATRIX_QUEUE_DEPTH=4 NPU_VECTOR_QUEUE_DEPTH=4 NPU_CNN_QUEUE_DEPTH=4 NPU_STREAM_FIFO_DEPTH=8}
set npu_area_strategy 2
set npu_threads 8
set npu_system_mhz 10
set npu_cnn_dsp 1
set npu_place_before_capacity_check 1
set npu_sources [list \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include/cv32e40p_pkg.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include/cv32e40p_apu_core_pkg.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include/cv32e40p_fpu_pkg.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/common_cells/cf_math_pkg.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dm_pkg.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/clk_rst/tc_clk.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/clk_rst/pulp_clk_cells.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/clk_rst/cluster_clk_cells.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/common_cells/fifo_v3.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/common_cells/fifo_v2.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/common_cells/cdc_2phase.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/clk_rst/rstgen_bypass.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/clk_rst/rstgen.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/debug_rom.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dm_csrs.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dm_mem.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dm_sba.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dm_top.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dmi_cdc.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dmi_jtag_tap.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/debug/dmi_jtag.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/soc/rtl/mem/sram_ff.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_aligner.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_alu.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_alu_div.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_apu_disp.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_compressed_decoder.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_controller.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_core.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_cs_registers.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_decoder.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_ex_stage.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_ff_one.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_fifo.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_hwloop_regs.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_id_stage.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_if_stage.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_int_controller.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_load_store_unit.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_mult.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_obi_interface.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_popcnt.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_prefetch_buffer.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_prefetch_controller.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_sleep_unit.sv}] \
  [file join $run_dir {src/external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/rtl/cv32e40p_top.sv}] \
  [file join $run_dir {src/npu/rtl/common/npu_addr_pkg.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_stream_pkg.sv}] \
  [file join $run_dir {src/npu/rtl/common/npu_rr_select.sv}] \
  [file join $run_dir {src/npu/rtl/common/npu_clock_gate.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_cnn.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_cnn_mac.sv}] \
  [file join $run_dir {src/npu/rtl/top/npu_core.sv}] \
  [file join $run_dir {src/npu/rtl/interconnect/npu_data_regfile.sv}] \
  [file join $run_dir {src/npu/rtl/debug/npu_debug_boot.sv}] \
  [file join $run_dir {src/npu/rtl/debug/npu_jtag_debug.sv}] \
  [file join $run_dir {src/npu/rtl/matrix/npu_matmul.sv}] \
  [file join $run_dir {src/npu/rtl/matrix/npu_matrix_stream.sv}] \
  [file join $run_dir {src/npu/rtl/control/npu_mmio.sv}] \
  [file join $run_dir {src/npu/rtl/top/npu_soc.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_stream.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_stream_control.sv}] \
  [file join $run_dir {src/npu/rtl/cnn/npu_stream_engine.sv}] \
  [file join $run_dir {src/npu/rtl/vector/npu_vector.sv}] \
  [file join $run_dir {src/npu/rtl/vector/npu_vector_stream.sv}] \
  [file join $run_dir {src/npu/rtl/interconnect/xbar.sv}] \
  [file join $run_dir {src/npu/rtl/interconnect/xbar_stream.sv}] \
  [file join $run_dir {src/npu/rtl/interconnect/npu_multi_read.sv}] \
  [file join $run_dir {src/npu/rtl/quant/npu_shared_quant.sv}] \
  [file join $run_dir {src/npu/rtl/common/npu_store_pack.sv}] \
  [file join $run_dir {src/npu/fpga/ego1/ego1_soc_top.sv}] \
  [file join $run_dir {src/npu/fpga/ego1/cv32e40p_register_file_lutram.sv}] \
]
