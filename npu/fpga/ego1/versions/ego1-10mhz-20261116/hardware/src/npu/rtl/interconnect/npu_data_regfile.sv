// Eight flip-flop banks, each with one read and one independent byte-write port.
// Ordinary reads and writes each have one lane per logical half; gather shares
// only the physical read ports. Same-edge read/write returns the old word.
module npu_data_regfile #(
  parameter int GATHER_PORTS = 3,
  parameter int NUM_MASTERS = 8,
  ID_W = $clog2(NUM_MASTERS)
) (
  input logic clk_i, rst_ni,
  input logic [NUM_MASTERS-1:0] req_i, we_i,
  input logic [NUM_MASTERS-1:0][3:0] be_i,
  input logic [NUM_MASTERS-1:0][31:0] addr_i, wdata_i,
  input logic exclude_i,
  input logic [ID_W-1:0] excluded_owner_i,
  output logic [NUM_MASTERS-1:0] gnt_o, rvalid_o,
  output logic [NUM_MASTERS-1:0][31:0] rdata_o,
  input logic [GATHER_PORTS-1:0] gather_req_i,
  input logic [GATHER_PORTS-1:0][31:0] gather_addr_i,
  output logic [GATHER_PORTS-1:0] gather_gnt_o, gather_valid_o, gather_error_o,
  output logic [GATHER_PORTS-1:0][31:0] gather_data_o
);
  import npu_addr_pkg::*;
  localparam int ROW_BITS = RF_BANK_BITS - 2;
  localparam int GPW = GATHER_PORTS > 1 ? $clog2(GATHER_PORTS) : 1;
  (* ram_style="registers" *) logic [31:0] words[8][RF_BANK_WORDS/4];
  // Four ordinary arbitration lanes: read half0/half1, write half0/half1.
  logic [ID_W-1:0] rr[4], selected[4], reply_owner[2];
  logic [3:0][NUM_MASTERS-1:0] candidates, pick;
  logic [3:0] found;
  logic [NUM_MASTERS-1:0] ordinary_valid, write_acks, next_write_acks;
  logic [NUM_MASTERS-1:0][2:0] ordinary_bank;
  logic [3:0][2:0] lane_bank;
  logic [3:0][ROW_BITS-1:0] lane_row;
  logic [1:0][31:0] lane_write_data, reply_data, next_data;
  logic [1:0][3:0] lane_be;
  logic [1:0] reply_valid, next_valid;
  logic [GPW-1:0] gather_rr[8], gather_selected[8];
  logic [GATHER_PORTS-1:0] bad, next_gather_valid;
  logic [GATHER_PORTS-1:0][2:0] gather_bank;
  logic [7:0][GATHER_PORTS-1:0] gather_candidates, gather_pick, broadcast_mask;
  logic [7:0] gather_found, read_bank, gather_take, write_bank, prefer_gather;
  logic [7:0][ROW_BITS-1:0] read_row, write_row;
  logic [7:0][31:0] write_data, bank_data;
  logic [7:0][3:0] write_be;
  logic [GATHER_PORTS-1:0][31:0] next_gather_data;
  function automatic logic [2:0] bank_id(input logic [31:0] a);
    return {a[RF_BANK_BITS+2], a[3:2] ^ a[6:5]};
  endfunction
  for (genvar m = 0; m < NUM_MASTERS; m++) begin : g_ordinary_decode
    assign ordinary_bank[m] = bank_id(addr_i[m]);
    assign ordinary_valid[m] = req_i[m] && is_rf_address(addr_i[m]) &&
        addr_i[m][1:0] == 0 && !(exclude_i && excluded_owner_i == ID_W'(m));
    for (genvar h = 0; h < 2; h++) begin : g_half
      assign candidates[h][m] = ordinary_valid[m] && !we_i[m] && ordinary_bank[m][2] == 1'(h);
      assign candidates[h+2][m] = ordinary_valid[m] && we_i[m] && ordinary_bank[m][2] == 1'(h);
    end
  end
  for (genvar lane = 0; lane < 4; lane++) begin : g_ordinary_select
    npu_rr_select #(.N(NUM_MASTERS), .IW(ID_W)) i_select (
      .req_i(candidates[lane]), .first_i(rr[lane]), .grant_o(pick[lane]),
      .valid_o(found[lane]), .index_o(selected[lane])
    );
  end
  for (genvar p = 0; p < GATHER_PORTS; p++) begin : g_gather_decode
    assign gather_bank[p] = bank_id(gather_addr_i[p]);
    assign bad[p] = gather_req_i[p] && (!is_rf_address(gather_addr_i[p]) || gather_addr_i[p][1:0] != 0);
    for (genvar b = 0; b < 8; b++)
      assign gather_candidates[b][p] = gather_req_i[p] && !bad[p] && gather_bank[p] == 3'(b);
  end
  for (genvar b = 0; b < 8; b++) begin : g_gather_select
    npu_rr_select #(.N(GATHER_PORTS), .IW(GPW)) i_select (
      .req_i(gather_candidates[b]), .first_i(gather_rr[b]), .grant_o(gather_pick[b]),
      .valid_o(gather_found[b]), .index_o(gather_selected[b])
    );
  end
  always_comb begin
    lane_bank = 0;
    lane_row = 0;
    lane_write_data = 0;
    lane_be = 0;
    for (int lane = 0; lane < 4; lane++)
      for (int m = 0; m < NUM_MASTERS; m++) begin
        lane_bank[lane] |= ordinary_bank[m] & {3{pick[lane][m]}};
        lane_row[lane] |= addr_i[m][RF_BANK_BITS+1:4] & {ROW_BITS{pick[lane][m]}};
        if (lane >= 2) begin
          lane_write_data[lane-2] |= wdata_i[m] & {32{pick[lane][m]}};
          lane_be[lane-2] |= be_i[m] & {4{pick[lane][m]}};
        end
      end
    gnt_o = 0;
    rvalid_o = write_acks;
    rdata_o = 0;
    gather_gnt_o = bad & {GATHER_PORTS{rst_ni}};
    next_gather_valid = bad & {GATHER_PORTS{rst_ni}};
    next_gather_data = 0;
    next_valid = 0;
    next_data = 0;
    next_write_acks = 0;
    read_bank = 0;
    gather_take = 0;
    write_bank = 0;
    read_row = 0;
    write_row = 0;
    write_data = 0;
    write_be = 0;
    broadcast_mask = 0;
    for (int b = 0; b < 8; b++) begin
      logic ordinary_read;
      int h;
      h = b / 4;
      ordinary_read = found[h] && lane_bank[h] == 3'(b);
      // Writes never compete with gather or ordinary reads. No forwarding is
      // needed: response flops sample pre-edge data before the byte write NBA.
      if (rst_ni && found[h+2] && lane_bank[h+2] == 3'(b)) begin
        write_bank[b] = 1;
        write_row[b] = lane_row[h+2];
        write_data[b] = lane_write_data[h];
        write_be[b] = lane_be[h];
        gnt_o |= pick[h+2];
        next_write_acks |= pick[h+2];
      end
      if (rst_ni && ordinary_read && (!gather_found[b] || !prefer_gather[b])) begin
        read_bank[b] = 1;
        read_row[b] = lane_row[h];
        gnt_o |= pick[h];
      end else if (rst_ni && gather_found[b]) begin
        read_bank[b] = 1;
        gather_take[b] = 1;
        for (int p = 0; p < GATHER_PORTS; p++)
          read_row[b] |= gather_addr_i[p][RF_BANK_BITS+1:4] & {ROW_BITS{gather_pick[b][p]}};
        // Gather requests for the identical word share one physical read.
        for (int p = 0; p < GATHER_PORTS; p++) begin
          broadcast_mask[b][p] = gather_candidates[b][p] &&
              gather_addr_i[p][RF_BANK_BITS+1:4] == read_row[b];
          gather_gnt_o[p] |= broadcast_mask[b][p];
        end
      end
      bank_data[b] = words[b][read_row[b]];
      if (read_bank[b] && !gather_take[b]) begin
        next_valid[h] = 1;
        next_data[h] |= bank_data[b];
      end
      for (int p = 0; p < GATHER_PORTS; p++) begin
        next_gather_valid[p] |= broadcast_mask[b][p];
        next_gather_data[p] |= bank_data[b] & {32{broadcast_mask[b][p]}};
      end
    end
    for (int m = 0; m < NUM_MASTERS; m++)
      for (int h = 0; h < 2; h++) begin
        rvalid_o[m] |= reply_valid[h] && reply_owner[h] == ID_W'(m);
        rdata_o[m] |= reply_data[h] & {32{reply_valid[h] && reply_owner[h] == ID_W'(m)}};
      end
  end
  for (genvar b = 0; b < 8; b++) begin : g_bank
    always_ff @(posedge clk_i)
      if (write_bank[b])
        for (int k = 0; k < 4; k++)
          if (write_be[b][k]) words[b][write_row[b]][k*8+:8] <= write_data[b][k*8+:8];
    always_ff @(posedge clk_i or negedge rst_ni)
      if (!rst_ni) begin
        prefer_gather[b] <= 0;
        gather_rr[b] <= 0;
      end else if (read_bank[b]) begin
        prefer_gather[b] <= !gather_take[b];
        if (gather_take[b])
          gather_rr[b] <= gather_selected[b] == GPW'(GATHER_PORTS-1) ? '0 : gather_selected[b]+1'b1;
      end
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      for (int lane = 0; lane < 4; lane++) rr[lane] <= 0;
      reply_valid <= 0;
      reply_data <= 0;
      reply_owner[0] <= 0;
      reply_owner[1] <= 0;
      write_acks <= 0;
      gather_valid_o <= 0;
      gather_error_o <= 0;
      gather_data_o <= 0;
    end else begin
      reply_valid <= next_valid;
      reply_data <= next_data;
      write_acks <= next_write_acks;
      gather_valid_o <= next_gather_valid;
      gather_error_o <= bad;
      gather_data_o <= next_gather_data;
      for (int h = 0; h < 2; h++)
        if (next_valid[h]) reply_owner[h] <= selected[h];
      for (int lane = 0; lane < 4; lane++)
        if (found[lane] && gnt_o[selected[lane]])
          rr[lane] <= selected[lane] == ID_W'(NUM_MASTERS-1) ? '0 : selected[lane]+1'b1;
    end
endmodule
