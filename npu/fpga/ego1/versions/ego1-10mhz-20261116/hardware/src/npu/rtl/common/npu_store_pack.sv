// Coalesce consecutive byte stores within one aligned word. Data and destination
// are fixed at input acceptance. Seal at full word/task tail or before a layout
// change. No FIFO-token merging. Flush cancels only stores not yet granted.
module npu_store_pack (
  input logic clk_i,
  rst_ni,
  flush_i,
  enable_i,
  input logic valid_i,
  output logic ready_o,
  input logic [31:0] addr_i,
  input logic [7:0] data_i,
  input logic last_i,
  output logic busy_o,
  req_o,
  output logic [31:0] addr_o,
  data_o,
  output logic [3:0] be_o,
  output logic [2:0] count_o,
  output logic [3:0] cancelled_o,
  input logic gnt_i
);
  logic valid, sealed, merge;
  logic [3:0] next_be;
  assign merge = valid && addr_i[31:2] == addr_o[31:2] && !be_o[addr_i[1:0]];
  assign next_be = (valid ? be_o : 4'b0) | (4'b1 << addr_i[1:0]);
  assign req_o = valid && !flush_i && (sealed || !enable_i || (valid_i && !merge));
  assign ready_o = !flush_i && (!valid || (merge && !req_o));
  assign busy_o = valid;
  assign cancelled_o = flush_i && valid ? {1'b0, count_o} : 4'b0;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid <= 0;
      sealed <= 0;
      be_o <= 0;
      count_o <= 0;
      addr_o <= 0;
      data_o <= 0;
    end else if (flush_i) begin
      valid <= 0;
      sealed <= 0;
      be_o <= 0;
      count_o <= 0;
    end else begin
      if (req_o && gnt_i) begin
        valid <= 0;
        sealed <= 0;
        be_o <= 0;
        count_o <= 0;
      end
      if (valid_i && ready_o) begin
        valid <= 1;
        addr_o <= {addr_i[31:2], 2'b0};
        data_o[8*addr_i[1:0]+:8] <= data_i;
        be_o <= next_be;
        count_o <= valid ? count_o + 1'b1 : 3'd1;
        sealed <= last_i || next_be == 4'hf;
      end
    end
  end
endmodule
