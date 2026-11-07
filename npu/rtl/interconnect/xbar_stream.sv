// Address-routed ordered channels. A write pushes one masked 32-bit word; a
// read pops one word. No tensor addressing/replay or arithmetic is implicit.
// Requests stall on full/empty, and every grant receives a next-cycle reply.
module xbar_stream #(
  parameter int MASTERS = 8,
  CHANNELS = 4,
  DEPTH = 16,
  ID_W = $clog2(MASTERS),
  PW = $clog2(DEPTH)
) (
  input logic clk_i,
  rst_ni,
  input logic [MASTERS-1:0] req_i,
  we_i,
  input logic [MASTERS-1:0][3:0] be_i,
  input logic [MASTERS-1:0][31:0] addr_i,
  wdata_i,
  output logic [MASTERS-1:0] gnt_o,
  rvalid_o,
  output logic [MASTERS-1:0][31:0] rdata_o
);
  import npu_addr_pkg::*;
  logic [31:0] data[CHANNELS][DEPTH];
  logic [PW-1:0] head[CHANNELS], tail[CHANNELS];
  logic [PW:0] count[CHANNELS];
  logic [ID_W-1:0] read_rr[CHANNELS], write_rr[CHANNELS], reader[CHANNELS], writer[CHANNELS];
  logic [CHANNELS-1:0] pop, push;
  logic [MASTERS-1:0][31:0] next_data;
  initial begin
    if (CHANNELS != 4 || DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "Invalid xbar stream geometry");
  end
  logic [CHANNELS-1:0][MASTERS-1:0] read_candidates, write_candidates, read_pick, write_pick;
  logic [CHANNELS-1:0] read_found, write_found;
  logic [CHANNELS-1:0][31:0] write_word;
  for (genvar m = 0; m < MASTERS; m++) begin : g_decode
    wire valid_address = req_i[m] && is_stream_address(addr_i[m]) && addr_i[m][1:0] == 0;
    for (genvar c = 0; c < CHANNELS; c++) begin : g_channel
      assign read_candidates[c][m] = valid_address && addr_i[m][9:8] == 2'(c) && !we_i[m];
      assign write_candidates[c][m] = valid_address && addr_i[m][9:8] == 2'(c) && we_i[m];
    end
  end
  for (genvar c = 0; c < CHANNELS; c++) begin : g_arbiters
    npu_rr_select #(
      .N (MASTERS),
      .IW(ID_W)
    ) i_reader (
      .req_i  (read_candidates[c]),
      .first_i(read_rr[c]),
      .grant_o(read_pick[c]),
      .valid_o(read_found[c]),
      .index_o(reader[c])
    );
    npu_rr_select #(
      .N (MASTERS),
      .IW(ID_W)
    ) i_writer (
      .req_i  (write_candidates[c]),
      .first_i(write_rr[c]),
      .grant_o(write_pick[c]),
      .valid_o(write_found[c]),
      .index_o(writer[c])
    );
  end
  always_comb begin
    gnt_o = 0;
    next_data = 0;
    pop = 0;
    push = 0;
    write_word = 0;
    for (int c = 0; c < CHANNELS; c++) begin
      logic [31:0] payload;
      // One-hot payload selection. A masked-off byte is zero in the FIFO.
      for (int m = 0; m < MASTERS; m++)
      for (int b = 0; b < 4; b++)
      write_word[c][8*b+:8] |= wdata_i[m][8*b+:8] & {8{write_pick[c][m] && be_i[m][b]}};
      pop[c] = rst_ni && count[c] != 0 && read_found[c];
      push[c] = rst_ni && (count[c] < DEPTH || pop[c]) && write_found[c];
      if (count[c] == 0 && push[c] && read_found[c]) pop[c] = 1;
      payload = count[c] == 0 ? write_word[c] : data[c][head[c]];
      for (int m = 0; m < MASTERS; m++) begin
        gnt_o[m] |= (pop[c] && read_pick[c][m]) || (push[c] && write_pick[c][m]);
        next_data[m] |= payload & {32{pop[c] && read_pick[c][m]}};
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 0;
      rdata_o <= 0;
      for (int c = 0; c < CHANNELS; c++) begin
        head[c] <= 0;
        tail[c] <= 0;
        count[c] <= 0;
        read_rr[c] <= 0;
        write_rr[c] <= 0;
      end
    end else begin
      rvalid_o <= gnt_o;
      rdata_o <= next_data;
      for (int c = 0; c < CHANNELS; c++) begin
        case ({
          push[c], pop[c]
        })
          2'b10: count[c] <= count[c] + 1'b1;
          2'b01: count[c] <= count[c] - 1'b1;
          default: ;
        endcase
        if (pop[c]) begin
          head[c] <= head[c] + 1'b1;
          read_rr[c] <= reader[c] == ID_W'(MASTERS - 1) ? 0 : reader[c] + 1'b1;
        end
        if (push[c]) begin
          data[c][tail[c]] <= write_word[c];
          tail[c] <= tail[c] + 1'b1;
          write_rr[c] <= writer[c] == ID_W'(MASTERS - 1) ? 0 : writer[c] + 1'b1;
        end
      end
    end
  end
endmodule
