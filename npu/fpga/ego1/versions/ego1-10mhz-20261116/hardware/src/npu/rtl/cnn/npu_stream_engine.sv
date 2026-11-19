// Three-word circular prefetch per row, with response-to-MAC forwarding.
// RF gather supplies operands/weights; an independent RF sink overlaps stores
// with ordinary SRAM reads. Software owns masks, strides and RF live ranges.
module npu_stream_engine #(
  parameter int RF_SINK = 0
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
  output logic [31:0] observe_o,
  output logic [3:0] quant_cancelled_o,
  output logic [3:0] quant_written_o,
  quant_write_fault_o,
  output logic filtered_final_o,
  output logic quant_final_o,
  input logic clk_i,
  rst_ni,
  start_i,
  input npu_stream_pkg::stream_config_t config_i,
  input npu_stream_pkg::stream_task_t command_i,
  output npu_stream_pkg::stream_events_t events_o,
  output logic req_o,
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
  import npu_stream_pkg::*;
  import npu_addr_pkg::*;
  localparam int MACS = 9;
  typedef enum logic [2:0] {
    IDLE,
    START,
    WAIT_INPUT,
    RUN,
    DRAIN
  } state_t;
  typedef enum logic [1:0] {
    BIDLE,
    WREQ,
    AREQ,
    STORE
  } load_t;
  state_t state;
  load_t load_state, pending_type;
  stream_config_t cfg;
  stream_task_t cmd;
  logic [4:0] task_count;
  assign task_count = {1'b0, cmd.count_m1} + 5'd1;
  logic [7:0] cursor;
  logic [3:0] position;
  logic [14:0] row_start[3], row_cursor[3], weight_base, weight_start, weight_ptr;
  logic [12:0] low_word[3];
  logic [31:0] window_data[3][3];
  logic [2:0] window_valid[3];
  logic [1:0] window_head[3];
  logic signed [7:0] weights[2][9];
  logic bank, load_bank, pending_bank, load_active, weights_sent;
  logic [1:0] weights_ready;
  logic [2:0] wanted, row_inflight, port_pending, port_seed;
  logic [2:0] gather_weight, port_weight, port_weight_last;
  logic [2:0][1:0] port_weight_word;
  logic [2:0][1:0] wanted_slot, port_slot;
  logic [2:0][12:0] wanted_word;
  logic [1:0] seed_valid, seed_inflight;
  logic [31:0] seed[2];
  logic seed_ready;
  logic [31:0] current_seed;
  logic [2:0] request_seed_slot, port_seed_slot;
  logic ready, tap_valid;
  logic [3:0] tap_count;
  logic [3:0] output_position;
  logic output_final;
  logic [31:0] output_address;
  logic [31:0] logical_address, pack_address, pack_data, write_data;
  logic [3:0] pack_be, write_be;
  logic [2:0] pack_count;
  logic pack_mode, pack_ready, pack_busy, pack_req, pack_gnt, write_final;
  logic accepted, write_selected, rf_write_selected, fault, drained;
  localparam int RESULT_DEPTH = 4;
  logic [RESULT_DEPTH-1:0][4:0] result_tags;
  logic [1:0] result_head, result_tail, raw_head;
  logic [2:0] result_count;
  logic result_pop;
  assign result_pop = mac_result_valid_i && mac_result_ready_o;
  assign {output_final, output_position} = result_tags[result_head];
  assign quant_final_o = result_tags[raw_head][4];
  assign filtered_final_o = output_final;
  assign logical_address=output_final && quant_enable_i ?
    quant_dst_i + (quant_pack_i ? 32'(cmd.dst_words)+32'(output_position) : 4*(32'(cmd.dst_words)+32'(output_position))) :
    {17'h10000,15'((output_final ? cfg.dst+{cmd.dst_words,2'b0}:cfg.partial)+{output_position,2'b0})};
  assign pack_mode = output_final && quant_enable_i && quant_pack_i && !is_stream_address(
      logical_address
  );
  npu_store_pack i_write_pack (
    .clk_i,
    .rst_ni,
    .flush_i    (fault || start_i),
    .enable_i   (quant_enable_i && quant_pack_i),
    .valid_i    (mac_result_valid_i && pack_mode),
    .ready_o    (pack_ready),
    .addr_i     (logical_address),
    .data_i     (mac_result_data_i[7:0]),
    .last_i     (output_position + 5'd1 == task_count),
    .busy_o     (pack_busy),
    .req_o      (pack_req),
    .addr_o     (pack_address),
    .data_o     (pack_data),
    .be_o       (pack_be),
    .count_o    (pack_count),
    .cancelled_o(quant_cancelled_o),
    .gnt_i      (pack_gnt)
  );
  assign output_address = pack_req ? pack_address : logical_address;
  assign write_final = pack_req || output_final;
  assign write_data = pack_req ? pack_data : mac_result_data_i;
  assign write_be = pack_req ? pack_be : 4'hf;
  assign pack_gnt = pack_req && (rf_write_selected ? rf_sink_gnt_i : accepted && we_o);
  logic pending, pending_write, pending_last;
  logic [1:0] pending_slot;
  logic [1:0] pending_row, selected_row;
  logic [1:0] selected_slot;
  logic [15:0] partial_busy;
  logic [2:0] pending_quant, rf_pending_quant;
  logic pending_partial;
  logic [3:0] pending_output_position;
  logic [14:0] pending_addr;
  logic rf_pending, rf_pending_partial;
  logic [3:0] rf_pending_position;
  logic partial_ack;
  logic [3:0] partial_ack_position;
  // Tags belong to the granted write, independent of later live config writes.
  assign quant_written_o = (pending && pending_write && rvalid_i && !error_i ? 4'(pending_quant) : 4'b0) + (rf_pending && rf_sink_rvalid_i && !rf_sink_error_i ? 4'(rf_pending_quant) : 4'b0);
  assign quant_write_fault_o = (pending && pending_write && rvalid_i && error_i ? 4'(pending_quant) : 4'b0) + (rf_pending && rf_sink_rvalid_i && rf_sink_error_i ? 4'(rf_pending_quant) : 4'b0);
  assign observe_o = {
    state != IDLE,
    req_o,
    quant_pack_i,
    quant_enable_i,
    tap_valid,
    result_pending_i,
    mac_result_valid_i,
    (|seed_inflight),
    (|port_pending),
    rf_pending,
    pending,
    output_final,
    task_count,
    cursor,
    position,
    state
  };
  assign partial_ack=(pending && pending_write && pending_partial && rvalid_i && !error_i) || (rf_pending && rf_pending_partial && rf_sink_rvalid_i && !rf_sink_error_i);
  assign partial_ack_position=rf_pending && rf_pending_partial && rf_sink_rvalid_i ? rf_pending_position:pending_output_position;
  function automatic logic horizontal_valid(input int k);
    return !(position==0 && cmd.left_pad && k==0) &&
      !(position+1==task_count && cmd.right_pad && k==2);
  endfunction
  always_comb begin
    seed_ready = seed_valid[position[0]];
    current_seed = seed[position[0]];
    // Forward an RF reply directly to arithmetic; retain it only if stalled.
    for (int p = 0; p < 3; p++)
    if(port_pending[p] && port_seed[p] && port_seed_slot[p]==position[0] && gather_valid_i[p] && !gather_error_i[p]) begin
      seed_ready = 1;
      current_seed = gather_data_i[p];
    end
  end
  function automatic logic [1:0] ring_next(input logic [1:0] slot);
    return slot == 2 ? 2'd0 : slot + 2'd1;
  endfunction
  // Replies can feed a MAC on their arrival cycle; the same reply is retained
  // in its physical ring slot if arithmetic or output is backpressured.
  function automatic logic window_ready(input int r, input logic [1:0] slot);
    logic available;
    available = window_valid[r][slot];
    if(pending && rvalid_i && !error_i && !pending_write && pending_type==AREQ && pending_row==2'(r) && pending_slot==slot)
      available = 1;
    if(port_pending[r] && !port_seed[r] && !port_weight[r] && gather_valid_i[r] && !gather_error_i[r] && port_slot[r]==slot)
      available = 1;
    return available;
  endfunction
  function automatic logic [31:0] window_word(input int r, input logic [1:0] slot);
    logic [31:0] value;
    value = window_data[r][slot];
    if(pending && rvalid_i && !error_i && !pending_write && pending_type==AREQ && pending_row==2'(r) && pending_slot==slot)
      value = rdata_i;
    if(port_pending[r] && !port_seed[r] && !port_weight[r] && gather_valid_i[r] && !gather_error_i[r] && port_slot[r]==slot)
      value = gather_data_i[r];
    return value;
  endfunction
  // One in-flight input read per row. Physical ring slots survive a head
  // advance, so a prefetch reply never needs a data-copy/remap race.
  always_comb begin
    logic [14:0] a, last_address;
    logic [1:0] head, high, look;
    logic [12:0] last_word;
    ready = weights_ready[bank] && (cursor == 0 || seed_ready);
    wanted = 0;
    wanted_slot = 0;
    wanted_word = 0;
    for (int r = 0; r < 3; r++) begin
      head = window_head[r];
      high = ring_next(head);
      look = ring_next(high);
      a = row_cursor[r] + 15'(cmd.right_pad && position + 1 == task_count ? 1 : 2);
      // Only prefetch words containing a valid pixel in this tile.
      last_address=row_start[r]+(15'(task_count-1'b1)<<cfg.step2)+15'(cmd.right_pad ? 1:2);
      last_word = last_address[14:2];
      if (cmd.row_mask[r]) begin
        if (!window_ready(r, head)) begin
          ready = 0;
          if (!row_inflight[r]) begin
            wanted[r] = 1;
            wanted_slot[r] = head;
            wanted_word[r] = low_word[r];
          end
        end else if (a[14:2] != low_word[r] && !window_ready(r, high)) begin
          ready = 0;
          if (!row_inflight[r]) begin
            wanted[r] = 1;
            wanted_slot[r] = high;
            wanted_word[r] = low_word[r] + 1'b1;
          end
        end else if (!row_inflight[r]) begin
          if (!window_ready(r, high) && low_word[r] + 13'd1 <= last_word) begin
            wanted[r] = 1;
            wanted_slot[r] = high;
            wanted_word[r] = low_word[r] + 13'd1;
          end else if (!window_ready(r, look) && low_word[r] + 13'd2 <= last_word) begin
            wanted[r] = 1;
            wanted_slot[r] = look;
            wanted_word[r] = low_word[r] + 13'd2;
          end
        end
      end
    end
    mac_mask_o = 0;
    begin
      logic [2:0] horizontal;
      logic [1:0] live_rows, live_cols;
      for (int c = 0; c < 3; c++) horizontal[c] = horizontal_valid(c);
      live_rows = {1'b0, cmd.row_mask[0]} + {1'b0, cmd.row_mask[1]} + {1'b0, cmd.row_mask[2]};
      live_cols = {1'b0, horizontal[0]} + {1'b0, horizontal[1]} + {1'b0, horizontal[2]};
      tap_count = 4'(live_rows) * 4'(live_cols);
      for (int r = 0; r < 3; r++) begin
        logic [31:0] head_word, high_word;
        logic [47:0] pair_words;
        logic [23:0] pixels;
        head_word = window_word(r, window_head[r]);
        high_word = window_word(r, ring_next(window_head[r]));
        pair_words = {high_word[15:0], head_word};
        pixels = 24'(pair_words >> {row_cursor[r][1:0], 3'b0});
        // At a left border, low_word may describe the first real pixel,
        // while row_cursor points to the masked byte in the preceding word.
        if (row_cursor[r][14:2] != low_word[r]) pixels = {head_word[15:0], 8'b0};
        for (int c = 0; c < 3; c++) begin
          mac_mask_o[3*r+c] = cmd.row_mask[r] && horizontal[c];
          mac_a_o[3*r+c] = mac_mask_o[3*r+c] ? $signed({1'b0, pixels[8*c+:8]}) : 9'sd0;
          mac_w_o[3*r+c] = weights[bank][3*r+c];
        end
      end
    end
  end
  assign mac_valid_o = state == RUN && ready && (result_count < RESULT_DEPTH || result_pop);
  assign tap_valid = mac_valid_o && mac_ready_i;
  assign mac_flush_o = state == START || fault;
  assign mac_clear_o = cursor == 0;
  assign mac_load_o = cursor != 0;
  assign mac_emit_o = 1;
  assign mac_seed_o = current_seed;
  assign mac_offset_o = $signed({1'b0, cfg.offset});
  assign write_selected = pack_req || (mac_result_valid_i && !pack_mode && !pack_busy);
  assign rf_write_selected = RF_SINK && write_selected && (!write_final || is_rf_address(
      output_address
  ));
  assign rf_sink_req_o = rf_write_selected;
  assign rf_sink_addr_o = {output_address[31:2], 2'b0};
  assign rf_sink_be_o = write_be;
  assign rf_sink_wdata_o = write_data;
  assign accepted = req_o && gnt_i;
  assign drained=!pack_busy && result_count == 0 && !mac_result_valid_i && !result_pending_i && !pending && !rf_pending && port_pending==0 && row_inflight==0 && seed_inflight==0;
  assign fault=(rf_pending && rf_sink_rvalid_i && rf_sink_error_i) || (pending && rvalid_i && error_i) || (|(port_pending & gather_valid_i & gather_error_i));
  assign events_o.busy = state != IDLE;
  assign events_o.start = state == START;
  assign events_o.done = state == DRAIN && drained;
  assign events_o.fault = fault;
  assign events_o.issue = tap_valid;
  assign events_o.mac_valid = tap_valid;
  assign events_o.macs = tap_count;
  assign events_o.waiting = state == WAIT_INPUT || (state == RUN && !tap_valid);
  assign events_o.mem = 3'(rf_sink_req_o && rf_sink_gnt_i) + 3'(accepted) + 3'($countones(
      gather_req_o & gather_gnt_i
  ));
  always_comb begin
    logic [1:0] seed_selected;
    req_o = 0;
    we_o = 0;
    be_o = write_be;
    addr_o = 0;
    wdata_o = write_data;
    selected_row = 0;
    selected_slot = 0;
    load_state = BIDLE;
    gather_req_o = 0;
    gather_addr_o = 0;
    gather_weight = 0;
    seed_selected = 0;
    request_seed_slot = 0;
    if (!is_rf_address(
            {17'h10000, cfg.kernel}
        ) && load_active && !weights_sent && !(state == RUN && !ready && !is_rf_address(
            {17'h10000, cfg.src}
        ) && |wanted))
      load_state = WREQ;
    else if ((state == RUN || state == WAIT_INPUT) && !is_rf_address(
            {17'h10000, cfg.src}
        ) && |wanted)
      load_state = AREQ;
    if (write_selected && !rf_write_selected) begin
      req_o = 1;
      we_o = 1;
      addr_o = output_address;
    end else if (load_state == WREQ) begin
      req_o = 1;
      addr_o = {17'h10000, weight_ptr};
    end else if (load_state == AREQ) begin
      for (int r = 2; r >= 0; r--)
      if (wanted[r]) begin
        req_o = 1;
        selected_row = 2'(r);
        selected_slot = wanted_slot[r];
        addr_o = {17'h10000, wanted_word[r], 2'b0};
      end
    end
    if (req_o) begin
      if (we_o && write_final && is_stream_address(output_address))
        addr_o = {output_address[31:8], 8'b0};
      else if (!we_o && load_state == WREQ && is_stream_address({17'h10000, cfg.kernel}))
        addr_o = {17'h10000, cfg.kernel};
      else if (!we_o && load_state == AREQ && is_stream_address({17'h10000, cfg.src}))
        addr_o = {17'h10000, cfg.src};
    end
    if (state == RUN || state == WAIT_INPUT) begin
      for (int r = 0; r < 3; r++)
      if (is_rf_address({17'h10000, cfg.src}) && wanted[r] && !port_pending[r]) begin
        gather_req_o[r] = 1;
        gather_addr_o[r] = {17'h10000, wanted_word[r], 2'b0};
      end
      if (cursor != 0)
        for (int ahead = 0; ahead < 2; ahead++) begin
          int target;
          logic [1:0] slot;
          target = int'(position) + ahead;
          slot = target[0];
          if(target<int'(task_count) && (!partial_busy[target] || (partial_ack && partial_ack_position==4'(target))) && !seed_valid[slot] && !seed_inflight[slot])
            for (int p = 0; p < 3; p++)
            if (!seed_selected[slot] && !gather_req_o[p] && !port_pending[p]) begin
              gather_req_o[p] = 1;
              gather_addr_o[p] = {17'h10000, 15'(cfg.partial + 15'(target * 4))};
              request_seed_slot[p] = slot;
              seed_selected[slot] = 1;
            end
        end
    end  // RF-resident weights use a spare gather lane, independent of the
    // ordinary SRAM activation/partial-write port. At most one weight word
    // is issued per cycle; all RF replies arrive one cycle after their grant.
    if ((state == WAIT_INPUT || state == RUN) && is_rf_address(
            {17'h10000, cfg.kernel}
        ) && load_active && !weights_sent) begin
      logic picked;
      picked = 0;
      for (int p = 0; p < 3; p++)
      if (!picked && !gather_req_o[p] && !port_pending[p]) begin
        gather_req_o[p] = 1;
        gather_addr_o[p] = {17'h10000, weight_ptr};
        gather_weight[p] = 1;
        picked = 1;
      end
    end

    mac_result_ready_o = pack_mode ? pack_ready : !pack_busy && (rf_write_selected ? rf_sink_gnt_i : accepted && we_o);
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && pending && rvalid_i && !error_i && !pending_write) begin
      if (pending_type == WREQ)
        for (int t = 0; t < 9; t++) begin
          logic [14:0] a;
          a = weight_start + 15'(t);
          if (a[14:2] == pending_addr[14:2]) weights[pending_bank][t] <= rdata_i[a[1:0]*8+:8];
        end
      else if (pending_type == AREQ) window_data[pending_row][pending_slot] <= rdata_i;
    end
    for (int p = 0; p < 3; p++)
    if (port_pending[p] && gather_valid_i[p] && !gather_error_i[p] && !port_seed[p] && !port_weight[p])
      window_data[p][port_slot[p]] <= gather_data_i[p];
    // The nine-byte load spans at most three aligned words, so low two
    // word-address bits distinguish all replies. load_bank/start stay stable
    // until the last (in-order, one-cycle) response completes the load.
    for (int p = 0; p < 3; p++)
    if (port_pending[p] && port_weight[p] && gather_valid_i[p] && !gather_error_i[p])
      for (int t = 0; t < 9; t++) begin
        logic [14:0] a;
        a = weight_start + 15'(t);
        if (a[3:2] == port_weight_word[p]) weights[load_bank][t] <= gather_data_i[p][a[1:0]*8+:8];
      end

  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state <= IDLE;
      cfg <= '0;
      cmd <= '0;
      cursor <= 0;
      position <= 0;
      weight_base <= 0;
      weight_start <= 0;
      weight_ptr <= 0;
      bank <= 0;
      load_bank <= 0;
      pending_bank <= 0;
      load_active <= 0;
      weights_sent <= 0;
      weights_ready <= 0;
      row_inflight <= 0;
      port_pending <= 0;
      port_seed <= 0;
      port_weight <= 0;
      port_weight_last <= 0;
      port_weight_word <= 0;
      port_slot <= 0;
      seed[0] <= 0;
      seed[1] <= 0;
      seed_valid <= 0;
      seed_inflight <= 0;
      port_seed_slot <= 0;
      result_head <= 0;
      result_tail <= 0;
      raw_head <= 0;
      result_count <= 0;
      partial_busy <= 0;
      pending_quant <= 0;
      rf_pending_quant <= 0;
      pending_partial <= 0;
      pending_output_position <= 0;
      pending <= 0;
      rf_pending <= 0;
      rf_pending_partial <= 0;
      rf_pending_position <= 0;
      pending_type <= BIDLE;
      pending_write <= 0;
      pending_last <= 0;
      pending_slot <= 0;
      pending_row <= 0;
      pending_addr <= 0;
      for (int r = 0; r < 3; r++) begin
        row_start[r] <= 0;
        row_cursor[r] <= 0;
        low_word[r] <= 0;
        window_head[r] <= 0;
        window_valid[r] <= 0;
      end
    end else begin
      pending <= accepted;
      rf_pending <= rf_sink_req_o && rf_sink_gnt_i;
      if (rf_sink_req_o && rf_sink_gnt_i) begin
        rf_pending_quant <= pack_req ? pack_count : 3'(write_final && quant_enable_i);
        rf_pending_partial <= !write_final;
        rf_pending_position <= output_position;
      end
      if (accepted) begin
        pending_quant <= pack_req ? pack_count : 3'(we_o && write_final && quant_enable_i);
        pending_write <= we_o;
        pending_type <= load_state;
        pending_partial <= we_o && !write_final;
        pending_output_position <= output_position;
        pending_row <= selected_row;
        pending_slot <= selected_slot;
        // Keep the logical weight-word tag even when transport uses one FIFO endpoint.
        pending_addr <= !we_o && load_state == WREQ ? weight_ptr : addr_o[14:0];
        pending_bank <= load_bank;
        pending_last <= weight_ptr + 4 >= weight_start + 9;
        if (!we_o && load_state == WREQ) begin
          weight_ptr <= weight_ptr + 4;
          if (weight_ptr + 4 >= weight_start + 9) weights_sent <= 1;
        end
        if (!we_o && load_state == AREQ) row_inflight[selected_row] <= 1;
      end
      if (partial_ack) partial_busy[partial_ack_position] <= 0;
      if (pending && rvalid_i && !error_i && !pending_write) begin
        if (pending_type == WREQ && pending_last) begin
          weights_ready[pending_bank] <= 1;
          load_active <= 0;
        end
        if (pending_type == AREQ) begin
          window_valid[pending_row][pending_slot] <= 1;
          row_inflight[pending_row] <= 0;
        end
      end
      for (int p = 0; p < 3; p++) begin
        if (port_pending[p] && gather_valid_i[p]) begin
          port_pending[p] <= 0;
          if (port_weight[p]) begin
            if (port_weight_last[p] && !gather_error_i[p]) begin
              weights_ready[load_bank] <= 1;
              load_active <= 0;
            end
          end else if (port_seed[p]) begin
            seed_inflight[port_seed_slot[p]] <= 0;
            if (!gather_error_i[p]) begin
              seed[port_seed_slot[p]] <= gather_data_i[p];
              seed_valid[port_seed_slot[p]] <= 1;
            end
          end else begin
            row_inflight[p] <= 0;
            if (!gather_error_i[p]) window_valid[p][port_slot[p]] <= 1;
          end
        end
        if (gather_req_o[p] && gather_gnt_i[p]) begin
          port_pending[p] <= 1;
          port_weight[p] <= gather_weight[p];
          port_seed[p] <= !gather_weight[p] && !(is_rf_address({17'h10000, cfg.src}) && wanted[p]);
          if (gather_weight[p]) begin
            port_weight_word[p] <= weight_ptr[3:2];
            port_weight_last[p] <= weight_ptr + 4 >= weight_start + 9;
            weight_ptr <= weight_ptr + 4;
            if (weight_ptr + 4 >= weight_start + 9) weights_sent <= 1;
          end else if (is_rf_address({17'h10000, cfg.src}) && wanted[p]) begin
            row_inflight[p] <= 1;
            port_slot[p] <= wanted_slot[p];
          end else begin
            seed_inflight[request_seed_slot[p]] <= 1;
            port_seed_slot[p] <= request_seed_slot[p];
          end
        end
      end
      if (start_i) begin
        cfg <= config_i;
        cmd <= command_i;
        state <= START;
      end
      if (result_accept_i) raw_head <= raw_head + 1'b1;
      if (result_pop) result_head <= result_head + 1'b1;
      case ({
        tap_valid, result_pop
      })
        2'b10: result_count <= result_count + 1'b1;
        2'b01: result_count <= result_count - 1'b1;
        default: ;
      endcase
      if (tap_valid) begin
        result_tags[result_tail] <= {cursor + 1 == cfg.ci, position[3:0]};
        result_tail <= result_tail + 1'b1;
        seed_valid[position[0]] <= 0;
        if (cursor + 1 < cfg.ci) partial_busy[position[3:0]] <= 1;
        if (position + 1 == task_count) begin
          if (cursor + 1 == cfg.ci) state <= DRAIN;
          else begin
            cursor <= cursor + 1'b1;
            position <= 0;
            bank <= !bank;
            weights_ready[bank] <= 0;
            seed_valid <= 0;
            for (int r = 0; r < 3; r++) begin
              logic [14:0] a, first;
              a = row_start[r] + cfg.plane_stride;
              first = a + 15'(cmd.left_pad);
              row_start[r] <= a;
              row_cursor[r] <= a;
              low_word[r] <= first[14:2];
              window_head[r] <= 0;
              window_valid[r] <= 0;
            end
            state <= weights_ready[!bank] ? RUN : WAIT_INPUT;
          end
        end else begin
          position <= position + 1'b1;
          for (int r = 0; r < 3; r++) begin
            logic [14:0] a;
            a = row_cursor[r] + (cfg.step2 ? 15'd2 : 15'd1);
            row_cursor[r] <= a;
            if (a[14:2] != low_word[r]) begin
              low_word[r] <= a[14:2];
              window_head[r] <= ring_next(window_head[r]);
              window_valid[r][window_head[r]] <= 0;
            end
          end
        end
      end
      case (state)
        START: begin
          cursor <= 0;
          position <= 0;
          bank <= 0;
          load_bank <= 0;
          load_active <= 1;
          weights_sent <= 0;
          weights_ready <= 0;
          weight_base <= cfg.kernel;
          weight_start <= cfg.kernel;
          weight_ptr <= (cfg.kernel) & 15'h7ffc;
          begin
            logic [14:0] anchor;
            anchor=cfg.src+15'(int'(cmd.y)<<cfg.step2)*cfg.row_stride+15'((int'(cmd.x)<<cfg.step2)-1);
            for (int r = 0; r < 3; r++) begin
              logic [14:0] a, first;
              a = anchor + (r == 0 ? -cfg.row_stride : r == 2 ? cfg.row_stride : 15'b0);
              first = a + 15'(cmd.left_pad);
              row_start[r] <= a;
              row_cursor[r] <= a;
              low_word[r] <= first[14:2];
              window_head[r] <= 0;
              window_valid[r] <= 0;
            end
          end
          partial_busy <= 0;
          seed_valid <= 0;
          seed_inflight <= 0;
          row_inflight <= 0;
          port_pending <= 0;
          state <= WAIT_INPUT;
        end
        WAIT_INPUT: if (weights_ready[bank]) state <= RUN;
        DRAIN: if (drained) state <= IDLE;
        default: ;
      endcase
      if ((state == RUN || state == WAIT_INPUT && weights_ready[bank]) && cursor + 1 < cfg.ci && !load_active && !weights_ready[!bank]) begin
        weight_start <= weight_base + 15'(cursor + 1) * 15'd9;
        weight_ptr <= (weight_base + 15'(cursor + 1) * 15'd9) & 15'h7ffc;
        load_bank <= !bank;
        load_active <= 1;
        weights_sent <= 0;
      end
      if (fault) begin
        result_head <= 0;
        result_tail <= 0;
        raw_head <= 0;
        result_count <= 0;
        state <= IDLE;
        port_pending <= 0;
        row_inflight <= 0;
        seed_inflight <= 0;
        load_active <= 0;
      end
    end
  end
endmodule
