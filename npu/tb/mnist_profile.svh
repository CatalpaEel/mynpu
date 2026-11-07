// Observational testbench counters. CNN reasons are mutually exclusive priority bins.
int profile_stage = 0;
bit profile_enable = 0;
longint profile_count[7][45];
string profile_names[45] = '{
    "cycles",
    "cnn_busy",
    "cnn_issue",
    "cnn_weight",
    "cnn_output",
    "cnn_seed",
    "cnn_input",
    "cnn_other",
    "matrix_busy",
    "matrix_fetch",
    "matrix_words",
    "matrix_clear",
    "matrix_emit",
    "matrix_creq",
    "matrix_cwait",
    "matrix_dreq",
    "matrix_dwait",
    "vector_busy",
    "vector_exec",
    "vector_input_wait",
    "vector_load",
    "vector_store",
    "vector_other",
    "both_cnn_vector",
    "both_matrix_vector",
    "no_engine",
    "cnn_write_words",
    "matrix_read_words",
    "matrix_write_words",
    "vec_read_words",
    "vec_write_words",
    "cnn_stream_words",
    "cnn_stream_block",
    "matrix_req_stall",
    "vector_req_stall",
    "gather_conflict",
    "cnn_weight_words",
    "cnn_activation_words",
    "cnn_seed_read_words",
    "cnn_activation_gather_words",
    "cnn_weight_gather_words",
    "rf_sink_words",
    "rf_sink_sram_overlap",
    "rf_sink_gather_overlap",
    "rf_sink_stall"
};
task automatic profile_begin;
  profile_stage = 0;
  for (int l = 0; l < 7; l++) for (int c = 0; c < 45; c++) profile_count[l][c] = 0;
  profile_enable = 1;
endtask
always @(posedge clk)
  if (measure && profile_enable) begin
    if (1) profile_count[profile_stage][0]++;
    if (dut.i_core.i_stream.events.busy) profile_count[profile_stage][1]++;
    if (dut.i_core.i_stream.events.busy) begin
      if (dut.i_core.i_stream.i_engine.tap_valid) profile_count[profile_stage][2]++;
      else if(dut.i_core.i_stream.i_engine.state==dut.i_core.i_stream.i_engine.WAIT_INPUT || (dut.i_core.i_stream.i_engine.state==dut.i_core.i_stream.i_engine.RUN && !dut.i_core.i_stream.i_engine.weights_ready[dut.i_core.i_stream.i_engine.bank]))
        profile_count[profile_stage][3]++;
      else if(dut.i_core.i_stream.i_engine.state==dut.i_core.i_stream.i_engine.RUN && !dut.i_core.dot_ready)
        profile_count[profile_stage][4]++;
      else if(dut.i_core.i_stream.i_engine.state==dut.i_core.i_stream.i_engine.RUN && dut.i_core.i_stream.i_engine.cursor!=0 && !dut.i_core.i_stream.i_engine.seed_ready)
        profile_count[profile_stage][5]++;
      else if(dut.i_core.i_stream.i_engine.state==dut.i_core.i_stream.i_engine.RUN && !dut.i_core.i_stream.i_engine.ready)
        profile_count[profile_stage][6]++;
      else profile_count[profile_stage][7]++;
    end
    if (dut.i_core.mat_busy) profile_count[profile_stage][8]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.FETCH)
      profile_count[profile_stage][9]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.WAIT_WORDS)
      profile_count[profile_stage][10]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.CLEAR)
      profile_count[profile_stage][11]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.EMIT)
      profile_count[profile_stage][12]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.C_REQ)
      profile_count[profile_stage][13]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.C_WAIT)
      profile_count[profile_stage][14]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.D_REQ)
      profile_count[profile_stage][15]++;
    if (dut.i_core.i_matrix_stream.state == dut.i_core.i_matrix_stream.D_WAIT)
      profile_count[profile_stage][16]++;
    if (dut.i_core.vec_busy) profile_count[profile_stage][17]++;
    if (dut.i_core.vec_busy) begin
      if (dut.i_core.i_vector_stream.state == dut.i_core.i_vector_stream.EXEC)
        profile_count[profile_stage][18]++;
      else if(dut.i_core.i_vector_stream.state==dut.i_core.i_vector_stream.LOAD_REQ || dut.i_core.i_vector_stream.state==dut.i_core.i_vector_stream.LOAD_WAIT)
        profile_count[profile_stage][20]++;
      else if(dut.i_core.i_vector_stream.state==dut.i_core.i_vector_stream.D_REQ || dut.i_core.i_vector_stream.state==dut.i_core.i_vector_stream.D_WAIT)
        profile_count[profile_stage][21]++;
      else profile_count[profile_stage][22]++;
    end
    if (dut.i_core.i_stream.events.busy && dut.i_core.vec_busy) profile_count[profile_stage][23]++;
    if (dut.i_core.mat_busy && dut.i_core.vec_busy) profile_count[profile_stage][24]++;
    if (!dut.i_core.i_stream.events.busy && !dut.i_core.mat_busy && !dut.i_core.vec_busy)
      profile_count[profile_stage][25]++;
    if (dut.i_core.cnn_busy && dut.i_core.req[1] && dut.i_core.gnt[1] && dut.i_core.we[1])
      profile_count[profile_stage][26]++;
    if (dut.i_core.mat_busy && dut.i_core.req[5] && dut.i_core.gnt[5] && !dut.i_core.we[5])
      profile_count[profile_stage][27]++;
    if (dut.i_core.mat_busy && dut.i_core.req[5] && dut.i_core.gnt[5] && dut.i_core.we[5])
      profile_count[profile_stage][28]++;
    if (dut.i_core.req[2] && dut.i_core.gnt[2] && !dut.i_core.we[2])
      profile_count[profile_stage][29]++;
    if (dut.i_core.req[2] && dut.i_core.gnt[2] && dut.i_core.we[2])
      profile_count[profile_stage][30]++;
    if (dut.i_core.mat_busy && dut.i_core.req[1] && !dut.i_core.gnt[1])
      profile_count[profile_stage][33]++;
    if (dut.i_core.req[2] && !dut.i_core.gnt[2]) profile_count[profile_stage][34]++;
    if (|(dut.i_core.cnn_gather_req & ~dut.i_core.cnn_gather_gnt))
      profile_count[profile_stage][35]++;

    if (dut.i_core.i_stream.req_o && dut.i_core.i_stream.gnt_i && !dut.i_core.i_stream.we_o) begin
      if (dut.i_core.i_stream.i_engine.load_state == dut.i_core.i_stream.i_engine.WREQ)
        profile_count[profile_stage][36]++;
      if (dut.i_core.i_stream.i_engine.load_state == dut.i_core.i_stream.i_engine.AREQ)
        profile_count[profile_stage][37]++;
    end
    for (int p = 0; p < 3; p++)
    if (dut.i_core.cnn_gather_req[p] && dut.i_core.cnn_gather_gnt[p]) begin
      if (dut.i_core.i_stream.i_engine.gather_weight[p]) profile_count[profile_stage][40]++;
      else if(dut.i_core.i_stream.i_engine.cfg.src[14] && dut.i_core.i_stream.i_engine.wanted[p] && !dut.i_core.i_stream.i_engine.port_pending[p])
        profile_count[profile_stage][39]++;
      else profile_count[profile_stage][38]++;
    end
    if (dut.i_core.cnn_rf_sink_req && dut.i_core.cnn_rf_sink_gnt) begin
      profile_count[profile_stage][41]++;
      if (dut.i_core.req[1] && dut.i_core.gnt[1] && !dut.i_core.we[1] && !dut.i_core.addr[1][14])
        profile_count[profile_stage][42]++;
      if (|(dut.i_core.cnn_gather_req & dut.i_core.cnn_gather_gnt))
        profile_count[profile_stage][43]++;
    end
    if (dut.i_core.cnn_rf_sink_req && !dut.i_core.cnn_rf_sink_gnt)
      profile_count[profile_stage][44]++;
    if(dut.i_core.req[0] && dut.i_core.gnt[0] && dut.i_core.we[0] && dut.i_core.addr[0]==32'h80001f04) begin
      if (dut.i_core.wdata[0] != 32'(profile_stage + 1) || profile_stage >= 6)
        $fatal(1, "Bad layer progress");
      profile_stage++;
    end
  end
task automatic profile_finish(input int sample, input longint expected_cycles);
  longint total;
  total = 0;
  profile_enable = 0;
  if (profile_stage != 6) $fatal(1, "Missing layer progress");
  for (int l = 0; l < 7; l++) begin
    total += profile_count[l][0];
    $write("STAGE_PROFILE sample=%0d stage=%0d", sample, l);
    for (int c = 0; c < 45; c++) $write(" %s=%0d", profile_names[c], profile_count[l][c]);
    $write("\n");
    if(profile_count[l][1]!=profile_count[l][2]+profile_count[l][3]+profile_count[l][4]+profile_count[l][5]+profile_count[l][6]+profile_count[l][7])
      $fatal(1, "CNN profile partition");
  end
  if (total != expected_cycles) $fatal(1, "Profile sum %0d != elapsed %0d", total, expected_cycles);
endtask
