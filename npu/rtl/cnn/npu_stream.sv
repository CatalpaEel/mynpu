// Shared transfer/control shell; arithmetic is an external ready/valid unit.
`ifndef NPU_CNN_QUEUE_DEPTH
`define NPU_CNN_QUEUE_DEPTH 4
`endif
module npu_stream #(
  parameter int RF_SINK = 0,
  QUEUE_DEPTH = `NPU_CNN_QUEUE_DEPTH
) (
  output logic [3:0] rf_sink_be_o,
  output logic rf_sink_req_o,
  output logic [31:0] rf_sink_addr_o,
  rf_sink_wdata_o,
  input logic rf_sink_gnt_i,
  rf_sink_rvalid_i,
  rf_sink_error_i,
  input logic result_accept_i,
  input logic result_pending_i,
  input logic quant_enable_i,
  quant_pack_i,
  input logic [31:0] quant_dst_i,
  output logic [3:0] quant_cancelled_o,
  output logic [3:0] quant_written_o,
  quant_write_fault_o,
  output logic filtered_final_o,
  output logic quant_final_o,
  input logic clk_i,
  rst_ni,
  csr_req_i,
  csr_we_i,
  blocked_i,
  input logic [7:0] event_bits_i,
  output logic [7:0] event_signal_o,
  input logic [7:0] csr_addr_i,
  input logic [31:0] csr_wdata_i,
  output logic [31:0] csr_rdata_o,
  output logic csr_error_o,
  busy_o,
  done_o,
  irq_o,
  req_o,
  we_o,
  output logic [3:0] be_o,
  output logic [31:0] addr_o,
  wdata_o,
  input logic gnt_i,
  rvalid_i,
  error_i,
  input logic [31:0] rdata_i,
  output logic [2:0] gather_req_o,
  output logic [2:0][31:0] gather_addr_o,
  input logic [2:0] gather_gnt_i,
  gather_valid_i,
  gather_error_i,
  input logic [2:0][31:0] gather_data_i,
  output logic mac_valid_o,
  mac_flush_o,
  mac_clear_o,
  mac_load_o,
  mac_emit_o,
  output logic signed [8:0] mac_a_o[9],
  mac_offset_o,
  output logic signed [7:0] mac_w_o[9],
  output logic [8:0] mac_mask_o,
  output logic [31:0] mac_seed_o,
  input logic mac_ready_i,
  mac_result_valid_i,
  input logic [31:0] mac_result_data_i,
  output logic mac_result_ready_o
);
  npu_stream_pkg::stream_config_t config_q;
  npu_stream_pkg::stream_task_t command;
  npu_stream_pkg::stream_events_t events;
  logic start;
  logic [31:0] observe;
  npu_stream_control #(
    .QUEUE_DEPTH(QUEUE_DEPTH)
  ) i_control (
    .observe_i(observe),
    .quant_pack_i,
    .events_i (events),
    .config_o (config_q),
    .command_o(command),
    .start_o  (start),
    .*
  );
  npu_stream_engine #(
    .RF_SINK(RF_SINK)
  ) i_engine (
    .observe_o(observe),
    .start_i  (start),
    .config_i (config_q),
    .command_i(command),
    .events_o (events),
    .*
  );
endmodule
