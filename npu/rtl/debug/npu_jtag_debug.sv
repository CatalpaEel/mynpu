// RISC-V debug 0.13 TAP/DTM/DM, reusing the course library unchanged.
// Host and SBA share one ordered XBAR ingress. DM/TAP reset only on POR.
module npu_jtag_debug (
  input logic clk_i,
  rst_ni,
  tck_i,
  tms_i,
  td_i,
  output logic td_o,
  system_rst_no,
  debug_req_o,
  input logic hart_unavailable_i,
  input logic host_req_i,
  host_we_i,
  input logic [3:0] host_be_i,
  input logic [31:0] host_addr_i,
  host_wdata_i,
  output logic host_gnt_o,
  host_rvalid_o,
  host_error_o,
  output logic [31:0] host_rdata_o,
  output logic bus_req_o,
  bus_we_o,
  output logic [3:0] bus_be_o,
  output logic [31:0] bus_addr_o,
  bus_wdata_o,
  input logic bus_gnt_i,
  bus_rvalid_i,
  bus_error_i,
  input logic [31:0] bus_rdata_i,
  input logic dm_req_i,
  dm_we_i,
  input logic [3:0] dm_be_i,
  input logic [31:0] dm_addr_i,
  dm_wdata_i,
  output logic [31:0] dm_rdata_o
);
  dm::dmi_req_t dmi_req;
  dm::dmi_resp_t dmi_resp;
  dm::hartinfo_t hartinfo;
  logic req_valid, req_ready, resp_valid, resp_ready, ndmreset;
  logic sba_req, sba_we, sba_gnt, sba_rvalid;
  logic [3:0] sba_be;
  logic [31:0] sba_addr, sba_wdata, sba_rdata;
  logic pending, owner_sba, rr, pick_sba, allow, accepted, retire;
  // Never cut an accepted SBA response when ndmreset arrives. New requests
  // stop immediately; at most one finite-latency XBAR transaction is drained.
  rstgen i_reset (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni && !(ndmreset && !pending)),
    .test_mode_i(1'b0),
    .rst_no     (system_rst_no),
    .init_no    ()
  );
  assign hartinfo = '{
          zero1: '0,
          nscratch: 2,
          zero0: '0,
          dataaccess: 1'b1,
          datasize: dm::DataCount,
          dataaddr: dm::DataAddr
      };
  dmi_jtag i_dtm (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .testmode_i      (1'b0),
    .dmi_rst_no      (),
    .dmi_req_o       (dmi_req),
    .dmi_req_valid_o (req_valid),
    .dmi_req_ready_i (req_ready),
    .dmi_resp_i      (dmi_resp),
    .dmi_resp_ready_o(resp_ready),
    .dmi_resp_valid_i(resp_valid),
    .tck_i           (tck_i),
    .tms_i           (tms_i),
    .trst_ni         (rst_ni),
    .td_i            (td_i),
    .td_o            (td_o),
    .tdo_oe_o        ()
  );
  dm_top #(
    .NrHarts        (1),
    .BusWidth       (32),
    .SelectableHarts(1'b1)
  ) i_dm (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .testmode_i      (1'b0),
    .ndmreset_o      (ndmreset),
    .dmactive_o      (),
    .debug_req_o     (debug_req_o),
    .unavailable_i   (hart_unavailable_i),
    .hartinfo_i      (hartinfo),
    .slave_req_i     (dm_req_i),
    .slave_we_i      (dm_we_i),
    .slave_addr_i    (dm_addr_i),
    .slave_be_i      (dm_be_i),
    .slave_wdata_i   (dm_wdata_i),
    .slave_rdata_o   (dm_rdata_o),
    .master_req_o    (sba_req),
    .master_add_o    (sba_addr),
    .master_we_o     (sba_we),
    .master_wdata_o  (sba_wdata),
    .master_be_o     (sba_be),
    .master_gnt_i    (sba_gnt),
    .master_r_valid_i(sba_rvalid),
    .master_r_rdata_i(sba_rdata),
    .dmi_rst_ni      (rst_ni),
    .dmi_req_valid_i (req_valid),
    .dmi_req_ready_o (req_ready),
    .dmi_req_i       (dmi_req),
    .dmi_resp_valid_o(resp_valid),
    .dmi_resp_ready_i(resp_ready),
    .dmi_resp_o      (dmi_resp)
  );
  always_comb begin
    retire = pending && bus_rvalid_i;
    allow = system_rst_no && !ndmreset && (!pending || retire);
    pick_sba = sba_req && (!host_req_i || rr);
    bus_req_o = allow && (host_req_i || sba_req);
    bus_we_o = pick_sba ? sba_we : host_we_i;
    bus_be_o = pick_sba ? sba_be : host_be_i;
    bus_addr_o = pick_sba ? sba_addr : host_addr_i;
    bus_wdata_o = pick_sba ? sba_wdata : host_wdata_i;
    accepted = bus_req_o && bus_gnt_i;
    host_gnt_o = accepted && !pick_sba;
    sba_gnt = accepted && pick_sba;
    host_rvalid_o = retire && !owner_sba;
    sba_rvalid = retire && owner_sba;
    host_rdata_o = bus_rdata_i;
    host_error_o = bus_error_i;
    sba_rdata = bus_rdata_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending <= 0;
      owner_sba <= 0;
      rr <= 0;
    end else begin
      if (retire) pending <= 0;
      if (accepted) begin
        pending <= 1;
        owner_sba <= pick_sba;
        rr <= !pick_sba;
      end
    end
  end
endmodule
