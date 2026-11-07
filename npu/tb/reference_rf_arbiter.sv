// Frozen pre-optimization implementation for cycle-exact differential tests.
// Eight physical single-access banks; ordinary masters retain two logical lanes.
// A separate three-address gather port reads up to 96 bits/cycle, subject to bank
// conflicts. Every grant, including an invalid gather address, replies next cycle.
module npu_data_regfile_reference #(
  parameter int GATHER_PORTS = 3,
  parameter int NUM_MASTERS = 8,
  ID_W = $clog2(NUM_MASTERS)
) (
  input logic clk_i,
  rst_ni,
  input logic [NUM_MASTERS-1:0] req_i,
  we_i,
  input logic [NUM_MASTERS-1:0][3:0] be_i,
  input logic [NUM_MASTERS-1:0][31:0] addr_i,
  wdata_i,
  input logic exclude_i,
  input logic [ID_W-1:0] excluded_owner_i,
  output logic [NUM_MASTERS-1:0] gnt_o,
  rvalid_o,
  output logic [NUM_MASTERS-1:0][31:0] rdata_o,
  input logic [GATHER_PORTS-1:0] gather_req_i,
  input logic [GATHER_PORTS-1:0][31:0] gather_addr_i,
  output logic [GATHER_PORTS-1:0] gather_gnt_o,
  gather_valid_o,
  gather_error_o,
  output logic [GATHER_PORTS-1:0][31:0] gather_data_o
);
  import npu_addr_pkg::*;
  localparam int ROW_BITS   = RF_BANK_BITS - 2;
  localparam int OWNER_BITS = $clog2(NUM_MASTERS + GATHER_PORTS);
  // Each logical half is split four ways. XOR skew preserves byte addresses
  // while spreading common row strides; no fully connected multi-read array.
  (* ram_style="registers" *) logic [31:0] words[8][RF_BANK_WORDS/4];
  logic [ID_W-1:0] rr[2], selected[2];
  logic [1:0] found;
  logic [7:0] take, write_bank, prefer_gather;
  localparam int GPW = $clog2(GATHER_PORTS);
  logic [GPW-1:0] gather_rr[8];
  logic [7:0][ROW_BITS-1:0] row;
  logic [7:0][OWNER_BITS-1:0] owner;
  logic [7:0][31:0] write_data, bank_data;
  logic [1:0] reply_valid, next_valid;
  logic [ID_W-1:0] reply_owner[2];
  logic [1:0][31:0] reply_data, next_data;
  logic [GATHER_PORTS-1:0] next_gather_valid;
  logic [GATHER_PORTS-1:0][31:0] next_gather_data;
  logic [7:0][3:0] write_be;
  logic [GATHER_PORTS-1:0] bad;
  logic [7:0][GATHER_PORTS-1:0] broadcast_mask;
  function automatic logic [2:0] bank_id(input logic [31:0] a);
    return {a[RF_BANK_BITS+2], (a[3:2] ^ a[6:5])};
  endfunction
  always_comb begin
    gnt_o = 0;
    rvalid_o = 0;
    rdata_o = 0;
    gather_gnt_o = 0;
    next_gather_valid = 0;
    next_gather_data = 0;
    next_valid = 0;
    next_data = 0;
    bad = 0;
    take = 0;
    broadcast_mask = 0;
    write_bank = 0;
    row = 0;
    owner = 0;
    write_data = 0;
    write_be = 0;
    found = 0;
    for (int h = 0; h < 2; h++) begin
      selected[h] = rr[h];
      for (int k = 0; k < NUM_MASTERS; k++) begin
        int candidate;
        candidate = (int'(rr[h]) + k) % NUM_MASTERS;
        if (!found[h] && req_i[candidate] && is_rf_address(
                addr_i[candidate]
            ) && addr_i[candidate][1:0] == 0 && addr_i[candidate][RF_BANK_BITS+2] == 1'(h) &&
                !(exclude_i && ID_W'(candidate) == excluded_owner_i)) begin
          found[h] = 1;
          selected[h] = ID_W'(candidate);
        end
      end
    end
    for (int p = 0; p < GATHER_PORTS; p++) begin
      bad[p] = gather_req_i[p] && (!is_rf_address(gather_addr_i[p]) || gather_addr_i[p][1:0] != 0);
      gather_gnt_o[p] = bad[p] && rst_ni;
      next_gather_valid[p] = bad[p] && rst_ni;
    end
    for (int b = 0; b < 8; b++) begin
      logic legacy, wide_found;
      int h, wp;
      h = b / 4;
      legacy = found[h] && bank_id(addr_i[selected[h]]) == 3'(b);
      wide_found = 0;
      wp = 0;
      for (int offset = 0; offset < GATHER_PORTS; offset++) begin
        int p;
        p = (int'(gather_rr[b]) + offset) % GATHER_PORTS;
        if (!wide_found && gather_req_i[p] && !bad[p] && bank_id(gather_addr_i[p]) == 3'(b)) begin
          wide_found = 1;
          wp = p;
        end
      end
      if (rst_ni && legacy && (!wide_found || !prefer_gather[b])) begin
        take[b] = 1;
        owner[b] = OWNER_BITS'(selected[h]);
        row[b] = addr_i[selected[h]][RF_BANK_BITS+1:4];
        write_bank[b] = we_i[selected[h]];
        write_data[b] = wdata_i[selected[h]];
        write_be[b] = be_i[selected[h]];
        gnt_o[selected[h]] = 1;
      end else if (rst_ni && wide_found) begin
        take[b] = 1;
        owner[b] = OWNER_BITS'(NUM_MASTERS + wp);
        row[b] = gather_addr_i[wp][RF_BANK_BITS+1:4];
        // Identical word requests share one bank read and one payload reply.
        for (int p = 0; p < GATHER_PORTS; p++)
        if (gather_req_i[p] && !bad[p] && gather_addr_i[p] == gather_addr_i[wp]) begin
          gather_gnt_o[p] = 1;
          broadcast_mask[b][p] = 1;
        end
      end
      // Exactly one payload read mux per physical bank, shared by all owners.
      bank_data[b] = words[b][row[b]];
      if (take[b]) begin
        if (int'(owner[b]) < NUM_MASTERS) begin
          next_valid[b/4] = 1;
          next_data[b/4] = write_bank[b] ? 0 : bank_data[b];
        end else begin
          for (int p = 0; p < GATHER_PORTS; p++)
          if (broadcast_mask[b][p]) begin
            next_gather_valid[p] = 1;
            next_gather_data[p] = bank_data[b];
          end
        end
      end
    end
    for (int h = 0; h < 2; h++)
    if (reply_valid[h]) begin
      rvalid_o[reply_owner[h]] = 1;
      rdata_o[reply_owner[h]] = reply_data[h];
    end
  end
  for (genvar b = 0; b < 8; b++) begin : g_bank
    // Payload deliberately has no reset. A bank never reads and writes for two
    // different requests on one edge; a write acknowledgement carries zero.
    always_ff @(posedge clk_i)
      if (take[b] && write_bank[b])
        for (int k = 0; k < 4; k++)
          if (write_be[b][k]) words[b][row[b]][k*8+:8] <= write_data[b][k*8+:8];
    always_ff @(posedge clk_i or negedge rst_ni)
      if (!rst_ni) begin
        prefer_gather[b] <= 0;
        gather_rr[b] <= 0;

      end else begin
        if (take[b]) begin
          // Alternate legacy/gather service when both remain active.
          prefer_gather[b] <= int'(owner[b]) < NUM_MASTERS;
          if (int'(owner[b]) >= NUM_MASTERS)
            gather_rr[b]<=int'(owner[b])-NUM_MASTERS==GATHER_PORTS-1 ? 0 : GPW'(int'(owner[b])-NUM_MASTERS+1);
        end
      end
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      rr[0] <= 0;
      rr[1] <= 0;
      reply_valid <= 0;
      reply_data <= 0;
      reply_owner[0] <= 0;
      reply_owner[1] <= 0;
      gather_valid_o <= 0;
      gather_error_o <= 0;
      gather_data_o <= 0;
    end else begin
      reply_valid <= next_valid;
      reply_data <= next_data;
      gather_valid_o <= next_gather_valid;
      gather_error_o <= bad;
      gather_data_o <= next_gather_data;
      for (int h = 0; h < 2; h++) if (next_valid[h]) reply_owner[h] <= selected[h];
      for (int h = 0; h < 2; h++)
      if (found[h] && gnt_o[selected[h]])
        rr[h] <= selected[h] == ID_W'(NUM_MASTERS - 1) ? '0 : selected[h] + 1'b1;
    end
endmodule
