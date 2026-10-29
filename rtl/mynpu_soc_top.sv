`include "axi/typedef.svh"
`include "axi/assign.svh"

// Integration derived from lab3; third_party sources remain unmodified.
module mynpu_soc_top #(
    parameter integer CPU_SRAM_BYTES = 8192,
    parameter integer NPU_SRAM_BYTES = 8192,
    parameter integer NPU_LANES = 4,
    parameter integer NPU_IRQ_ID = 16,
    parameter bit DUAL_BANK_SHARED = 1'b1,
    parameter integer NPU_ACT_CACHE_WORDS = 1,
    parameter bit NPU_MMIO_GRID = 1'b1,
    parameter bit COMPACT_HOST_BUS = 1'b1,
    parameter integer NPU_GRID_CACHE_WORDS = 32,
    parameter integer NPU_GRID_TOPOLOGY = 3,
    parameter bit JTAG_BOOT_CONTROL = 1'b1,
    parameter bit USE_FPGA_BRAM = 1'b1,
    parameter bit USE_ASIC_SRAM = 1'b0,
    parameter CPU_INIT_FILE = "",
    parameter NPU_INIT_FILE = "",
    parameter logic [31:0] FIRMWARE_MAILBOX_ADDR = 32'h8000_1fc0
) (
    input   logic   clk_i,
    input   logic   rst_ni,
    input   logic   boot_ready_i,
    output  logic   npu_irq_o,
    output  logic   cpu_debug_halted_o,
    output  logic [31:0] firmware_status_o,
    output  logic [31:0] firmware_error_o,
    output  logic [31:0] firmware_result_o,
    output  logic [31:0] firmware_cycles_o,
    input   logic   tck_i,
    input   logic   tms_i,
    input   logic   td_i,
    output  logic   td_o
);

  import mynpu_soc_pkg::*;
  localparam bit NATIVE_HOST = DUAL_BANK_SHARED && NPU_MMIO_GRID && COMPACT_HOST_BUS;
  logic [31:0] cpu_irq;
  localparam integer NPU_MEM_BACKEND = USE_ASIC_SRAM ? 2 : (USE_FPGA_BRAM ? 1 : 0);
  assign cpu_irq = (32'd1 << NPU_IRQ_ID) & {32{npu_irq_o}};

  logic ndmreset;
  logic ndmreset_n;

  rstgen i_rstgen_main (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni & (~ndmreset)),
      .test_mode_i (1'b0),
      .rst_no      (ndmreset_n),
      .init_no     ()
  );

  AXI_BUS #(
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_ID_WIDTH   (2),
      .AXI_USER_WIDTH (1)
  ) slave[2:0]();

  AXI_BUS #(
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_ID_WIDTH   (4),
      .AXI_USER_WIDTH (1)
  ) master[(DUAL_BANK_SHARED ? 3 : 4)-1:0]();

  localparam axi_pkg::xbar_cfg_t AXI_XBAR_CFG = '{
      NoSlvPorts:         3,
      NoMstPorts:         DUAL_BANK_SHARED ? 3 : 4,
      MaxMstTrans:        1,
      MaxSlvTrans:        1,
      FallThrough:        1'b0,
      LatencyMode:        axi_pkg::CUT_ALL_PORTS,
      AxiIdWidthSlvPorts: 2,
      AxiIdUsedSlvPorts:  2,
      UniqueIds:          1'b0,
      AxiAddrWidth:       32,
      AxiDataWidth:       32,
      NoAddrRules:        4
  };

  axi_pkg::xbar_rule_32_t [3:0] addr_map;

  localparam int IDX_BOOT = 0;
  localparam int IDX_SRAM = 1;
  localparam int IDX_NPU  = DUAL_BANK_SHARED ? 1 : 2;
  localparam int IDX_DM   = DUAL_BANK_SHARED ? 2 : 3;

  assign addr_map = '{
      '{ idx: IDX_BOOT, start_addr: BOOT_BASE, end_addr: BOOT_BASE + 64 },
      '{ idx: IDX_SRAM, start_addr: SRAM_BASE, end_addr: SRAM_BASE + (DUAL_BANK_SHARED ? 16384 : CPU_SRAM_BYTES) },
      '{ idx: IDX_NPU,  start_addr: NPU_BASE,  end_addr: NPU_BASE  + NPU_LENGTH  },
      '{ idx: IDX_DM,   start_addr: DM_BASE,   end_addr: DM_BASE   + DM_LENGTH   }
  };

  if(!NATIVE_HOST)begin:g_axi_fabric
  axi_xbar_intf #(
      .AXI_USER_WIDTH (1),
      .Cfg            (AXI_XBAR_CFG),
      .rule_t         (axi_pkg::xbar_rule_32_t)
  ) i_axi_xbar (
      .clk_i                 (clk_i),
      .rst_ni                (ndmreset_n),
      .test_i                (1'b0),
      .slv_ports             (slave),
      .mst_ports             (master),
      .addr_map_i            (addr_map),
      .en_default_mst_port_i ('0),
      .default_mst_port_i    ('0)
  );

  end
  logic           instr_req;
  logic           instr_gnt;
  logic           instr_rvalid;
  logic [31:0]    instr_addr;
  logic [31:0]    instr_rdata;
  logic           data_req;
  logic           data_gnt;
  logic           data_rvalid;
  logic           data_we;
  logic [3:0]     data_be;
  logic [31:0]    data_addr;
  logic [31:0]    data_wdata;
  logic [31:0]    data_rdata;
  logic           data_valid;
  logic           debug_req_valid;
  logic           debug_req_ready;
  dm::dmi_req_t   debug_req;
  logic           debug_resp_valid;
  logic           debug_resp_ready;
  dm::dmi_resp_t  debug_resp;
  logic           debug_req_irq;
  localparam logic [31:0] DM_HALT_ADDR      = dm::HaltAddress[31:0];
  localparam logic [31:0] DM_EXCEPTION_ADDR = dm::ExceptionAddress[31:0];

  cv32e40p_top #(
      .COREV_PULP      (0),
      .COREV_CLUSTER   (0),
      .FPU             (0),
      .FPU_ADDMUL_LAT  (0),
      .FPU_OTHERS_LAT  (0),
      .ZFINX           (0),
      .NUM_MHPMCOUNTERS(0)
  ) i_cpu (
      .clk_i               (clk_i),
      .rst_ni              (ndmreset_n),
      .pulp_clock_en_i     ('0),
      .scan_cg_en_i        ('0),
      .boot_addr_i         (BOOT_BASE),
      .mtvec_addr_i        (BOOT_BASE),
      .dm_halt_addr_i      (DM_HALT_ADDR),
      .hart_id_i           ('0),
      .dm_exception_addr_i (DM_EXCEPTION_ADDR),
      .instr_req_o         (instr_req),
      .instr_gnt_i         (instr_gnt),
      .instr_rvalid_i      (instr_rvalid),
      .instr_addr_o        (instr_addr),
      .instr_rdata_i       (instr_rdata),
      .data_req_o          (data_req),
      .data_gnt_i          (data_gnt),
      .data_rvalid_i       (data_valid),
      .data_we_o           (data_we),
      .data_be_o           (data_be),
      .data_addr_o         (data_addr),
      .data_wdata_o        (data_wdata),
      .data_rdata_i        (data_rdata),
      .irq_i               (cpu_irq),
      .irq_ack_o           (),
      .irq_id_o            (),
      .debug_req_i         (debug_req_irq),
      .debug_havereset_o   (),
      .debug_running_o     (),
      .debug_halted_o      (cpu_debug_halted_o),
      .fetch_enable_i      (boot_ready_i),
      .core_sleep_o        ()
  );

  `AXI_TYPEDEF_ALL(axi,
                   logic [31:0],
                   logic [1:0],
                   logic [31:0],
                   logic [3:0],
                   logic)

  axi_req_t  instr_axi_req;
  axi_resp_t instr_axi_resp;
  axi_req_t  data_axi_req;
  axi_resp_t data_axi_resp;
  axi_req_t  dm_axi_m_req;
  axi_resp_t dm_axi_m_resp;

  `AXI_ASSIGN_FROM_REQ(slave[0], instr_axi_req)
  `AXI_ASSIGN_TO_RESP(instr_axi_resp, slave[0])
  `AXI_ASSIGN_FROM_REQ(slave[1], data_axi_req)
  `AXI_ASSIGN_TO_RESP(data_axi_resp, slave[1])
  `AXI_ASSIGN_FROM_REQ(slave[2], dm_axi_m_req)
  `AXI_ASSIGN_TO_RESP(dm_axi_m_resp, slave[2])

  if(!NATIVE_HOST)begin:g_axi_cpu
  assign data_valid = data_rvalid | data_axi_resp.b_valid;

  axi_adapter #(
      .ADDR_WIDTH         (32),
      .DATA_WIDTH         (32),
      .AXI_DATA_WIDTH     (32),
      .AXI_ID_WIDTH       (2),
      .MAX_OUTSTANDING_AW (7),
      .axi_req_t          (axi_req_t),
      .axi_rsp_t          (axi_resp_t)
  ) i_axi_adapter_instr (
      .clk_i                 (clk_i),
      .rst_ni                (ndmreset_n),
      .req_i                 (instr_req),
      .type_i                (1'b0),
      .amo_i                 (4'b0000),
      .gnt_o                 (instr_gnt),
      .addr_i                (instr_addr),
      .we_i                  (1'b0),
      .wdata_i               ('0),
      .be_i                  (4'b1111),
      .size_i                (2'b10),
      .id_i                  (2'b01),
      .valid_o               (instr_rvalid),
      .rdata_o               (instr_rdata),
      .id_o                  (),
      .critical_word_o       (),
      .critical_word_valid_o (),
      .axi_req_o             (instr_axi_req),
      .axi_resp_i            (instr_axi_resp)
  );

  axi_adapter #(
      .ADDR_WIDTH         (32),
      .DATA_WIDTH         (32),
      .AXI_DATA_WIDTH     (32),
      .AXI_ID_WIDTH       (2),
      .MAX_OUTSTANDING_AW (7),
      .axi_req_t          (axi_req_t),
      .axi_rsp_t          (axi_resp_t)
  ) i_axi_adapter_data (
      .clk_i                 (clk_i),
      .rst_ni                (ndmreset_n),
      .req_i                 (data_req),
      .type_i                (1'b0),
      .amo_i                 (4'b0000),
      .gnt_o                 (data_gnt),
      .addr_i                (data_addr),
      .we_i                  (data_we),
      .wdata_i               (data_wdata),
      .be_i                  (data_be),
      .size_i                (2'b10),
      .id_i                  (2'b10),
      .valid_o               (data_rvalid),
      .rdata_o               (data_rdata),
      .id_o                  (),
      .critical_word_o       (),
      .critical_word_valid_o (),
      .axi_req_o             (data_axi_req),
      .axi_resp_i            (data_axi_resp)
  );

  end
  dmi_jtag i_dmi_jtag (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .dmi_rst_no      (),
      .testmode_i      (1'b0),
      .dmi_req_valid_o (debug_req_valid),
      .dmi_req_ready_i (debug_req_ready),
      .dmi_req_o       (debug_req),
      .dmi_resp_valid_i(debug_resp_valid),
      .dmi_resp_ready_o(debug_resp_ready),
      .dmi_resp_i      (debug_resp),
      .tck_i           (tck_i),
      .tms_i           (tms_i),
      .trst_ni         (rst_ni),
      .td_i            (td_i),
      .td_o            (td_o),
      .tdo_oe_o        ()
  );

  dm::hartinfo_t hartinfo;
  assign hartinfo = '{
      zero1      : '0,
      nscratch   : 2,
      zero0      : '0,
      dataaccess : 1'b1,
      datasize   : dm::DataCount,
      dataaddr   : dm::DataAddr
  };

  logic        dm_slave_req;
  logic        dm_slave_we;
  logic [31:0] dm_slave_addr;
  logic [3:0]  dm_slave_be;
  logic [31:0] dm_slave_wdata;
  logic [31:0] dm_slave_rdata;

  logic        dm_master_req;
  logic [31:0] dm_master_add;
  logic        dm_master_we;
  logic [31:0] dm_master_wdata;
  logic [3:0]  dm_master_be;
  logic        dm_master_gnt;
  logic        dm_master_r_valid;
  logic        dm_master_read_valid;
  logic [31:0] dm_master_r_rdata;

  if(!NATIVE_HOST)begin:g_axi_dm_slave
  axi2mem #(
      .AXI_ID_WIDTH   (4),
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_USER_WIDTH (1)
  ) i_dm_axi2mem (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .slave  (master[IDX_DM]),
      .req_o  (dm_slave_req),
      .we_o   (dm_slave_we),
      .addr_o (dm_slave_addr),
      .be_o   (dm_slave_be),
      .data_o (dm_slave_wdata),
      .user_i (1'b0),
      .user_o (),
      .data_i (dm_slave_rdata)
  );

  end
  dm_top #(
      .NrHarts         (1),
      .BusWidth        (32),
      .SelectableHarts (1'b1)
  ) i_dm_top (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni), // PoR(Power-on Reset)
      .testmode_i       (1'b0),
      .ndmreset_o       (ndmreset),
      .dmactive_o       (),
      .debug_req_o      (debug_req_irq),
      .unavailable_i    ('0),
      .hartinfo_i       (hartinfo),
      .slave_req_i      (dm_slave_req),
      .slave_we_i       (dm_slave_we),
      .slave_addr_i     (dm_slave_addr),
      .slave_be_i       (dm_slave_be),
      .slave_wdata_i    (dm_slave_wdata),
      .slave_rdata_o    (dm_slave_rdata),
      .master_req_o     (dm_master_req),
      .master_add_o     (dm_master_add),
      .master_we_o      (dm_master_we),
      .master_wdata_o   (dm_master_wdata),
      .master_be_o      (dm_master_be),
      .master_gnt_i     (dm_master_gnt),
      .master_r_valid_i (dm_master_r_valid),
      .master_r_rdata_i (dm_master_r_rdata),
      .dmi_rst_ni       (rst_ni),
      .dmi_req_valid_i  (debug_req_valid),
      .dmi_req_ready_o  (debug_req_ready),
      .dmi_req_i        (debug_req),
      .dmi_resp_valid_o (debug_resp_valid),
      .dmi_resp_ready_i (debug_resp_ready),
      .dmi_resp_o       (debug_resp)
  );

  if(!NATIVE_HOST)begin:g_axi_sba
  axi_adapter #(
      .ADDR_WIDTH         (32),
      .DATA_WIDTH         (32),
      .AXI_DATA_WIDTH     (32),
      .AXI_ID_WIDTH       (2),
      .MAX_OUTSTANDING_AW (7),
      .axi_req_t          (axi_req_t),
      .axi_rsp_t          (axi_resp_t)
  ) i_axi_adapter_dm (
      .clk_i                 (clk_i),
      .rst_ni                (rst_ni),
      .req_i                 (dm_master_req),
      .type_i                (1'b0),
      .amo_i                 (4'b0000),
      .gnt_o                 (dm_master_gnt),
      .addr_i                (dm_master_add),
      .we_i                  (dm_master_we),
      .wdata_i               (dm_master_wdata),
      .be_i                  (dm_master_be),
      .size_i                (2'b10),
      .id_i                  ('0),
      .valid_o               (dm_master_read_valid),
      .rdata_o               (dm_master_r_rdata),
      .id_o                  (),
      .critical_word_o       (),
      .critical_word_valid_o (),
      .axi_req_o             (dm_axi_m_req),
      .axi_resp_i            (dm_axi_m_resp)
  );

  // SBA must see write completion as well as read completion.
  assign dm_master_r_valid = dm_master_read_valid | dm_axi_m_resp.b_valid;

  end
  logic        boot_req;
  logic        boot_we;
  logic [31:0] boot_addr;
  logic [31:0] boot_wdata;
  logic [31:0] boot_rdata;
  logic [3:0] boot_be;

  generate if(JTAG_BOOT_CONTROL)begin:g_debug_boot
    mynpu_debug_boot #(.BUILD_ID(DUAL_BANK_SHARED ? 32'h544f5204 : 32'h4a541004),
      .CACHE_WORDS(DUAL_BANK_SHARED ? NPU_ACT_CACHE_WORDS : 0)) i_boot(
      .clk_i(clk_i),.rst_ni(ndmreset_n),.req_i(boot_req),.we_i(boot_we),
      .addr_i(boot_addr[5:2]),.be_i(boot_be),.wdata_i(boot_wdata),.rdata_o(boot_rdata));
  end else begin:g_legacy_boot
  bootram i_bootram (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .req_i (boot_req),
      .wen_i (boot_we),
      .addr_i(boot_addr[5:2]),
      .data_i(boot_wdata),
      .data_o(boot_rdata)
  );
  end endgenerate

  if(!NATIVE_HOST)begin:g_axi_boot
  axi2mem #(
      .AXI_ID_WIDTH   (4),
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_USER_WIDTH (1)
  ) i_axi2boot (
      .clk_i  (clk_i),
      .rst_ni (ndmreset_n),
      .slave  (master[IDX_BOOT]),
      .req_o  (boot_req),
      .we_o   (boot_we),
      .addr_o (boot_addr),
      .be_o   (boot_be),
      .data_o (boot_wdata),
      .user_i (1'b0),
      .user_o (),
      .data_i (boot_rdata)
  );

  end
  logic host_req,host_we,host_gnt,host_rv;
  logic[31:0]host_addr_bus,host_wd_bus,host_rd;
  logic[3:0]host_be_bus;
  logic pe_command_valid,pe_command_ready;
  if(NATIVE_HOST)begin:g_native_host
    // Ordered CPU data responses across the direct command port and shared bus.
    // The direct path is a single response slot, not an instruction FIFO.
    logic data_pending_q,data_fast_q;
    wire[2:0]grants,responses;wire[31:0]read_data[0:2];
    wire fast_address=data_we&&(&data_be)&&data_addr==32'h70000ffc;
    wire retire_data=data_pending_q&&(data_fast_q||responses[1]);
    wire allow_data=!data_pending_q||retire_data;
    wire[2:0] requests={dm_master_req,data_req&&!fast_address&&allow_data,instr_req};
    wire[2:0] writes={dm_master_we,data_we,1'b0};
    wire[31:0]addresses[0:2],write_data[0:2];
    wire[3:0]byte_enables[0:2];
    assign addresses[0]=instr_addr;assign addresses[1]=data_addr;assign addresses[2]=dm_master_add;
    assign write_data[0]=0;assign write_data[1]=data_wdata;assign write_data[2]=dm_master_wdata;
    assign byte_enables[0]=15;assign byte_enables[1]=data_be;assign byte_enables[2]=dm_master_be;
    assign instr_gnt=grants[0];assign instr_rvalid=responses[0];assign instr_rdata=read_data[0];
    assign pe_command_valid=data_req&&fast_address&&allow_data;
    assign data_gnt=fast_address?(data_req&&allow_data&&pe_command_ready):grants[1];
    assign data_rvalid=retire_data;assign data_valid=retire_data;
    assign data_rdata=data_fast_q?32'd0:read_data[1];
    always_ff @(posedge clk_i or negedge ndmreset_n)begin
      if(!ndmreset_n)begin data_pending_q<=0;data_fast_q<=0;end
      else begin
        if(retire_data)data_pending_q<=0;
        if(data_req&&data_gnt)begin data_pending_q<=1;data_fast_q<=fast_address;end
      end
    end
    assign dm_master_gnt=grants[2];assign dm_master_read_valid=responses[2];assign dm_master_r_valid=responses[2];assign dm_master_r_rdata=read_data[2];
    mynpu_host_arbiter i_host(.clk_i(clk_i),.rst_ni(ndmreset_n),.req_i(requests),.we_i(writes),
      .addr_i(addresses),.wdata_i(write_data),.be_i(byte_enables),.gnt_o(grants),.rvalid_o(responses),.rdata_o(read_data),
      .shared_req_o(host_req),.shared_we_o(host_we),.shared_addr_o(host_addr_bus),.shared_wdata_o(host_wd_bus),.shared_be_o(host_be_bus),
      .shared_gnt_i(host_gnt),.shared_rvalid_i(host_rv),.shared_rdata_i(host_rd),
      .boot_req_o(boot_req),.boot_we_o(boot_we),.boot_addr_o(boot_addr),.boot_wdata_o(boot_wdata),.boot_be_o(boot_be),.boot_rdata_i(boot_rdata),
      .dm_req_o(dm_slave_req),.dm_we_o(dm_slave_we),.dm_addr_o(dm_slave_addr),.dm_wdata_o(dm_slave_wdata),.dm_be_o(dm_slave_be),.dm_rdata_i(dm_slave_rdata));
  end

  if(!NATIVE_HOST)assign pe_command_valid=1'b0;

  generate if (DUAL_BANK_SHARED) begin : g_shared
    logic req,we,gnt,rv,err,host_write;
    logic [31:0] addr,wd,rd,host_addr,host_wd;
    logic [3:0] be,host_be;
    if(NATIVE_HOST)begin:g_native
      assign req=host_req;assign we=host_we;assign addr=host_addr_bus;assign wd=host_wd_bus;assign be=host_be_bus;
      assign host_gnt=gnt;assign host_rv=rv;assign host_rd=rd;
    end else begin:g_axi
    mynpu_axi_shared #(.ID_WIDTH(4)) i_bridge(
      .clk_i(clk_i),.rst_ni(ndmreset_n),.slave(master[IDX_NPU]),
      .req_o(req),.we_o(we),.addr_o(addr),.wdata_o(wd),.be_o(be),
      .gnt_i(gnt),.rvalid_i(rv),.rdata_i(rd),.error_i(err));
    end
    mynpu_torus_subsystem #(.MEM_BACKEND(NPU_MEM_BACKEND),.STREAM_CACHE_WORDS(NPU_GRID_CACHE_WORDS),
      .BANK0_INIT_FILE(CPU_INIT_FILE),.BANK1_INIT_FILE(NPU_INIT_FILE)) i_subsystem(
      .clk_i(clk_i),.rst_ni(ndmreset_n),.req_i(req),.we_i(we),.addr_i(addr),
      .wdata_i(wd),.be_i(be),.gnt_o(gnt),.rvalid_o(rv),.rdata_o(rd),.error_o(err),
      .command_valid_i(pe_command_valid),.command_word_i(data_wdata),.command_ready_o(pe_command_ready),
      .irq_o(npu_irq_o),.host_write_o(host_write),.host_addr_o(host_addr),
      .host_wdata_o(host_wd),.host_be_o(host_be));
    always_ff @(posedge clk_i or negedge ndmreset_n) begin
      if(!ndmreset_n)begin
        firmware_status_o<=0;firmware_error_o<=0;firmware_result_o<=0;firmware_cycles_o<=0;
      end else if(host_write&&(&host_be))case(host_addr)
        FIRMWARE_MAILBOX_ADDR:firmware_status_o<=host_wd;
        FIRMWARE_MAILBOX_ADDR+4:firmware_error_o<=host_wd;
        FIRMWARE_MAILBOX_ADDR+8:firmware_result_o<=host_wd;
        FIRMWARE_MAILBOX_ADDR+12:firmware_cycles_o<=host_wd;
        default:;
      endcase
    end
  end else begin : g_private
  assign pe_command_ready=1'b0;
  logic        sram_req;
  logic        sram_we;
  logic [31:0] sram_addr;
  logic [31:0] sram_wdata;
  logic [3:0]  sram_be;
  logic [31:0] sram_rdata;

  // Observe accepted SRAM writes for board self-test reporting. This does not
  // create another memory port or alter CPU/AXI behavior. The address must
  // match the firmware mailbox when changing the CPU memory layout.
  always_ff @(posedge clk_i or negedge ndmreset_n) begin
    if (!ndmreset_n) begin
      firmware_status_o <= '0;
      firmware_error_o <= '0;
      firmware_result_o <= '0;
      firmware_cycles_o <= '0;
    end else if (sram_req && sram_we && (&sram_be)) begin
      case (sram_addr)
        FIRMWARE_MAILBOX_ADDR:       firmware_status_o <= sram_wdata;
        FIRMWARE_MAILBOX_ADDR + 4:   firmware_error_o <= sram_wdata;
        FIRMWARE_MAILBOX_ADDR + 8:   firmware_result_o <= sram_wdata;
        FIRMWARE_MAILBOX_ADDR + 12:  firmware_cycles_o <= sram_wdata;
        default: ;
      endcase
    end
  end

  mynpu_sram #(
      .SRAM_BYTES(CPU_SRAM_BYTES), .INIT_FILE(CPU_INIT_FILE),
      .FPGA_BRAM(USE_FPGA_BRAM), .ASIC_MACRO(USE_ASIC_SRAM)
  ) i_mainmem (
      .clk_i  (clk_i),
      .rst_ni (ndmreset_n),
      .req_i  (sram_req),
      .we_i   (sram_we),
      .be_i   (sram_be),
      .addr_i (sram_addr),
      .wdata_i(sram_wdata),
      .rdata_o(sram_rdata)
  );

  axi2mem #(
      .AXI_ID_WIDTH   (4),
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_USER_WIDTH (1)
  ) i_axi2sram (
      .clk_i  (clk_i),
      .rst_ni (ndmreset_n),
      .slave  (master[IDX_SRAM]),
      .req_o  (sram_req),
      .we_o   (sram_we),
      .addr_o (sram_addr),
      .be_o   (sram_be),
      .data_o (sram_wdata),
      .user_i (1'b0),
      .user_o (),
      .data_i (sram_rdata)
  );

  // ==========================================================================
  logic        npu_req;
  logic        npu_we;
  logic [31:0] npu_addr;
  logic [31:0] npu_wdata;
  logic [3:0]  npu_be;
  logic [31:0] npu_rdata;

  axi2mem #(
      .AXI_ID_WIDTH   (4),
      .AXI_ADDR_WIDTH (32),
      .AXI_DATA_WIDTH (32),
      .AXI_USER_WIDTH (1)
  ) i_axi2npu (
      .clk_i  (clk_i),
      .rst_ni (ndmreset_n),
      .slave  (master[IDX_NPU]),
      .req_o  (npu_req),
      .we_o   (npu_we),
      .addr_o (npu_addr),
      .be_o   (npu_be),
      .data_o (npu_wdata),
      .user_i (1'b0),
      .user_o (),
      .data_i (npu_rdata)
  );

  cnn_npu_subsystem #(
      .LANES(NPU_LANES), .SRAM_BYTES(NPU_SRAM_BYTES),
      .MAX_LAYERS(8), .SHARED_SRAM(1), .MEM_BACKEND(NPU_MEM_BACKEND),
      .MEM_INIT_FILE(NPU_INIT_FILE)
  ) i_npu_subsystem (
      .clk_i  (clk_i),
      .rst_ni (ndmreset_n),
      .req_i  (npu_req),
      .we_i   (npu_we),
      .be_i   (npu_be),
      .addr_i (npu_addr),
      .wdata_i(npu_wdata),
      .rdata_o(npu_rdata),
      .irq_o  (npu_irq_o)
  );
  // ==========================================================================
  end endgenerate
endmodule
