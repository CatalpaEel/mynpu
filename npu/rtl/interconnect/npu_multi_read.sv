// One batch, up to three independent word reads. The caller owns arbitration
// between clients. RF uses gather; SRAM and FIFO reads use the ordinary port.
// Each accepted request is issued exactly once, including destructive FIFO pops.
module npu_multi_read #(
  parameter bit GATHER = 1
) (
  input logic clk_i,
  rst_ni,
  input logic valid_i,
  output logic ready_o,
  input logic [2:0] mask_i,
  input logic [2:0][31:0] addr_i,
  output logic valid_o,
  input logic ready_i,
  output logic [2:0][31:0] data_o,
  output logic [2:0] error_o,
  output logic [2:0] gather_req_o,
  output logic [2:0][31:0] gather_addr_o,
  input logic [2:0] gather_gnt_i,
  gather_valid_i,
  gather_error_i,
  input logic [2:0][31:0] gather_data_i,
  output logic req_o,
  output logic [31:0] addr_o,
  input logic gnt_i,
  rvalid_i,
  error_i,
  input logic [31:0] rdata_i
);
  import npu_addr_pkg::*;
  logic active, failed;
  logic response_fault;
  logic [2:0] needed, sent, received, rf;
  logic [2:0][31:0] addresses;
  logic pending;
  logic [1:0] owner, selected;
  logic found;
  assign response_fault = (pending && rvalid_i && error_i) || (|(gather_valid_i & gather_error_i & sent & needed & ~received));
  assign ready_o = !active;
  assign valid_o = active && ((received & needed) == needed);
  assign gather_addr_o = addresses;
  always_comb begin
    gather_req_o = active && !valid_o && !failed ? needed & rf & ~sent : 3'b0;
    found = 0;
    selected = 0;
    for (int p = 0; p < 3; p++)
    if (!found && needed[p] && !rf[p] && !sent[p]) begin
      selected = 2'(p);
      found = 1;
    end
    req_o = active && !valid_o && !failed && (!pending || rvalid_i) && !response_fault && found;
    addr_o = addresses[selected];
  end
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      active <= 0;
      failed <= 0;
      needed <= 0;
      sent <= 0;
      received <= 0;
      rf <= 0;
      addresses <= 0;
      data_o <= 0;
      error_o <= 0;
      pending <= 0;
      owner <= 0;
    end else begin
      if (valid_i && ready_o) begin
        active <= 1;
        failed <= 0;
        needed <= mask_i;
        addresses <= addr_i;
        sent <= 0;
        received <= 0;
        data_o <= 0;
        error_o <= 0;
        for (int p = 0; p < 3; p++) rf[p] <= GATHER && is_rf_address(addr_i[p]);
      end
      if (valid_o && ready_i) active <= 0;
      if (active && response_fault) begin
        failed <= 1;
        // Cancel only requests never granted. Already granted reads must drain.
        for (int p = 0; p < 3; p++)
        if (needed[p] && !sent[p] && !(gather_req_o[p] && gather_gnt_i[p]) && !(req_o && gnt_i && selected==2'(p)))
          received[p] <= 1;
      end
      for (int p = 0; p < 3; p++) begin
        if (gather_req_o[p] && gather_gnt_i[p]) sent[p] <= 1;
        if (active && needed[p] && rf[p] && sent[p] && !received[p] && gather_valid_i[p]) begin
          received[p] <= 1;
          data_o[p] <= gather_data_i[p];
          error_o[p] <= gather_error_i[p];
        end
      end
      if (pending && rvalid_i) begin
        pending <= 0;
        received[owner] <= 1;
        data_o[owner] <= rdata_i;
        error_o[owner] <= error_i;
      end
      // The old response uses old owner; a new grant replaces the pending tag.
      if (req_o && gnt_i) begin
        sent[selected] <= 1;
        owner <= selected;
        pending <= 1;
      end
    end
endmodule
