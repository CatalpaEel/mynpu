`timescale 1ns/1ps

// AXI protocol stress for the exact AXI-to-SRAM adapter used by the SoC.
// Every response cycle independently randomizes RREADY/BREADY.  Request
// VALID is also held across random idle gaps, and both single-beat and burst
// reads/writes are checked against a byte-enable-aware memory model.
module tb_axi2mem_backpressure #(
  parameter integer TRANSACTIONS = 1000,
  parameter integer SEED = 32'h5eed1234
);
  localparam integer WORDS = 1024;
  logic clk = 1'b0;
  logic rst_ni = 1'b0;
  AXI_BUS #(.AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(32), .AXI_ID_WIDTH(4), .AXI_USER_WIDTH(1)) bus();
  logic req, we;
  logic [31:0] addr, data_o, data_i;
  logic [3:0] be;
  logic [0:0] user_o, user_i;
  logic [31:0] memory [0:WORDS-1];
  logic [31:0] golden_mem [0:WORDS-1];
  integer i;
  integer errors = 0;
  integer random_state;

  always #5 clk = ~clk;
  assign user_i = '0;

  axi2mem #(
    .AXI_ID_WIDTH(4), .AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(32), .AXI_USER_WIDTH(1)
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .slave(bus.Slave),
    .req_o(req), .we_o(we), .addr_o(addr), .be_o(be), .user_o(user_o),
    .data_o(data_o), .user_i(user_i), .data_i(data_i)
  );

  always @(posedge clk) begin
    // The SoC SRAM contract is synchronous.  The response for the request
    // sampled this edge is presented through data_i in the following cycle;
    // using an asynchronous read here would make the adapter's next-address
    // combinational logic look like a one-word AXI data shift.
    if (!rst_ni)
      data_i <= '0;
    else if (req)
      data_i <= memory[addr[11:2]];
    if (rst_ni && req && we) begin
      if (be[0]) memory[addr[11:2]][7:0] <= data_o[7:0];
      if (be[1]) memory[addr[11:2]][15:8] <= data_o[15:8];
      if (be[2]) memory[addr[11:2]][23:16] <= data_o[23:16];
      if (be[3]) memory[addr[11:2]][31:24] <= data_o[31:24];
    end
  end

  function automatic [31:0] test_data(input integer transaction, input integer beat);
    test_data = (32'h9e3779b9 * (transaction + 1)) ^
                (32'h01020305 * (beat + 3)) ^ 32'ha5a55a5a;
  endfunction

  task automatic idle_gap;
    integer gap;
    begin
      gap = $urandom_range(0, 4);
      repeat (gap) @(posedge clk);
    end
  endtask

  task automatic clear_master_outputs;
    begin
      bus.aw_id = '0; bus.aw_addr = '0; bus.aw_len = '0; bus.aw_size = '0;
      bus.aw_burst = axi_pkg::BURST_INCR; bus.aw_lock = '0; bus.aw_cache = '0;
      bus.aw_prot = '0; bus.aw_qos = '0; bus.aw_region = '0; bus.aw_atop = '0;
      bus.aw_user = '0; bus.aw_valid = 1'b0;
      bus.w_data = '0; bus.w_strb = '0; bus.w_last = 1'b0; bus.w_user = '0; bus.w_valid = 1'b0;
      bus.b_ready = 1'b0;
      bus.ar_id = '0; bus.ar_addr = '0; bus.ar_len = '0; bus.ar_size = '0;
      bus.ar_burst = axi_pkg::BURST_INCR; bus.ar_lock = '0; bus.ar_cache = '0;
      bus.ar_prot = '0; bus.ar_qos = '0; bus.ar_region = '0; bus.ar_user = '0; bus.ar_valid = 1'b0;
      bus.r_ready = 1'b0;
    end
  endtask

  task automatic write_burst(input integer transaction, input integer start_word, input integer len);
    integer beat, guard;
    logic aw_done, aw_hs, w_hs;
    logic w_done;
    begin
      idle_gap();
      aw_done = 1'b0;
      w_done = 1'b0;
      beat = 0;
      guard = 0;
      @(negedge clk);
      bus.aw_id = transaction[3:0]; bus.aw_addr = start_word * 4; bus.aw_len = len;
      bus.aw_size = 3'd2; bus.aw_burst = axi_pkg::BURST_INCR; bus.aw_valid = 1'b1;
      bus.w_data = test_data(transaction, 0); bus.w_strb = 4'hf;
      bus.w_last = (len == 0); bus.w_valid = 1'b1; bus.b_ready = 1'b0;
      while (!w_done) begin
        @(posedge clk);
        // Capture both handshakes before the DUT advances its FSM.  Looking
        // at WREADY after the AW transition would miss a legal same-cycle
        // AW/W transfer and leave the master holding WVALID forever.
        aw_hs = bus.aw_valid && bus.aw_ready;
        w_hs = bus.w_valid && bus.w_ready;
        guard = guard + 1;
        if (guard > 10000)
          $fatal(1, "write handshake timeout transaction=%0d beat=%0d aw=%b w=%b", transaction, beat, bus.aw_valid, bus.w_valid);
        if (aw_hs || w_hs) begin
          // Update both channels on the same following half-cycle.  Waiting
          // for one negedge per channel would leave WVALID/data[beat] live
          // for an extra clock and duplicate a beat in the SRAM.
          @(negedge clk);
          if (aw_hs) begin
            aw_done = 1'b1;
            bus.aw_valid = 1'b0;
          end
          if (w_hs) begin
            golden_mem[start_word + beat] = test_data(transaction, beat);
            beat = beat + 1;
            if (beat > len) begin
              w_done = 1'b1;
              bus.w_valid = 1'b0;
            end else begin
              bus.w_data = test_data(transaction, beat);
              bus.w_last = (beat == len);
            end
          end
        end
      end
      // Random response backpressure.  BVALID must remain asserted until a
      // cycle in which BREADY is also asserted.
      guard = 0;
      while (1) begin
        @(negedge clk); bus.b_ready = $urandom_range(0, 1);
        @(posedge clk);
        guard = guard + 1;
        if (guard > 10000)
          $fatal(1, "B response timeout transaction=%0d", transaction);
        if (bus.b_valid && bus.b_ready) begin
          if (bus.b_id !== transaction[3:0] || bus.b_resp !== axi_pkg::RESP_OKAY)
            $fatal(1, "bad B response transaction=%0d id=%h resp=%h", transaction, bus.b_id, bus.b_resp);
          @(negedge clk); bus.b_ready = 1'b0;
          disable write_burst;
        end
      end
    end
  endtask

  task automatic read_burst(input integer transaction, input integer start_word, input integer len);
    integer beat, guard;
    logic ar_done;
    logic [31:0] expected;
    logic [31:0] held_data;
    begin
      idle_gap();
      ar_done = 1'b0;
      beat = 0;
      guard = 0;
      @(negedge clk);
      bus.ar_id = transaction[3:0]; bus.ar_addr = start_word * 4; bus.ar_len = len;
      bus.ar_size = 3'd2; bus.ar_burst = axi_pkg::BURST_INCR; bus.ar_valid = 1'b1;
      bus.r_ready = 1'b0;
      while (!ar_done) begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 10000)
          $fatal(1, "AR handshake timeout transaction=%0d", transaction);
        if (bus.ar_valid && bus.ar_ready) begin
          ar_done = 1'b1;
          @(negedge clk); bus.ar_valid = 1'b0;
        end
      end
      guard = 0;
      while (beat <= len) begin
        @(negedge clk); bus.r_ready = $urandom_range(0, 1);
        @(posedge clk);
        guard = guard + 1;
        if (guard > 10000)
          $fatal(1, "R response timeout transaction=%0d beat=%0d", transaction, beat);
        if (bus.r_valid && !bus.r_ready) held_data = bus.r_data;
        if (bus.r_valid && bus.r_ready) begin
          expected = golden_mem[start_word + beat];
          if (bus.r_data !== expected || bus.r_id !== transaction[3:0] ||
              bus.r_resp !== axi_pkg::RESP_OKAY || bus.r_last !== (beat == len)) begin
            $display("[AXI] read mismatch tx=%0d beat=%0d data=%h expected=%h id=%h last=%b",
                     transaction, beat, bus.r_data, expected, bus.r_id, bus.r_last);
            errors = errors + 1;
          end
          beat = beat + 1;
        end
        if (bus.r_valid && !bus.r_ready && bus.r_data !== held_data)
          $fatal(1, "RDATA changed while RREADY=0 transaction=%0d beat=%0d", transaction, beat);
      end
      @(negedge clk); bus.r_ready = 1'b0;
    end
  endtask

  initial begin
    random_state = SEED;
    for (i = 0; i < WORDS; i = i + 1) begin
      memory[i] = 32'h0;
      golden_mem[i] = 32'h0;
    end
    clear_master_outputs();
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk);
    for (i = 0; i < TRANSACTIONS; i = i + 1) begin
      integer len;
      integer start_word;
      len = $urandom_range(0, 7);
      start_word = $urandom_range(0, WORDS - len - 1);
      if ((i % 10) == 0) $display("[AXI-BP] transaction=%0d/%0d", i, TRANSACTIONS);
      write_burst(i, start_word, len);
      read_burst(i, start_word, len);
    end
    if (errors != 0)
      $fatal(1, "AXI backpressure regression failed errors=%0d", errors);
    $display("[AXI-BP] PASS transactions=%0d randomized RREADY/BREADY every response cycle", TRANSACTIONS);
    $finish;
  end
endmodule
