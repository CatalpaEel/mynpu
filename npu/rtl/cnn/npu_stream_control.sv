// Configuration changes require an empty queue and idle transfer engine.
// FIFO payload is never reset; qcount invalidates stale entries.
module npu_stream_control #(
  parameter int QUEUE_DEPTH = 16
) (
  input logic quant_pack_i,
  input logic clk_i,
  rst_ni,
  csr_req_i,
  csr_we_i,
  blocked_i,
  pending_i,
  input logic [7:0] csr_addr_i,
  input logic [31:0] csr_wdata_i,
  input npu_stream_pkg::stream_events_t events_i,
  output npu_stream_pkg::stream_config_t config_o,
  output npu_stream_pkg::stream_task_t command_o,
  output logic start_o,
  output logic [31:0] csr_rdata_o,
  output logic csr_error_o,
  busy_o,
  done_o,
  irq_o
);
  import npu_stream_pkg::*;
  import npu_addr_pkg::*;
  localparam int PW = QUEUE_DEPTH > 1 ? $clog2(QUEUE_DEPTH) : 1;
  stream_config_t cfg;
  logic [31:0] command, queue[QUEUE_DEPTH];
  logic [PW-1:0] head, tail;
  logic [$clog2(QUEUE_DEPTH+1)-1:0] qcount;
  logic fault, push, known, writable, valid_write, valid_command;
  logic [31:0] completed, submitted, total_cycles, total_macs;
  function automatic logic [PW-1:0] advance(input logic [PW-1:0] p);
    return p == QUEUE_DEPTH - 1 ? '0 : p + 1'b1;
  endfunction
  assign config_o = cfg;
  assign command_o = stream_task_t'(queue[head]);
  assign busy_o = events_i.busy || qcount != 0;
  assign irq_o = done_o || fault;
  assign start_o = qcount != 0 && !events_i.busy && !blocked_i && !fault;
  assign valid_command=command[17:14]>=1 && command[17:14]<=STREAM_PARTIAL_WORDS &&
    cfg.ci!=0 && cfg.row_stride!=0 && cfg.plane_stride!=0;
  assign push=csr_req_i && csr_we_i && csr_addr_i==0 && csr_wdata_i[0] && !csr_error_o && valid_command;
  always_comb begin
    csr_rdata_o = 0;
    known = 1;
    writable = 1;
    valid_write = 1;
    case (csr_addr_i)
      'h00: ;
      'h04: begin
        csr_rdata_o = {29'b0, fault, done_o, busy_o};
        writable = 0;
      end
      'h08: begin
        csr_rdata_o = {17'h10000, cfg.src};
        valid_write = data_range_ok(csr_wdata_i, 1) && csr_wdata_i[1:0] == 0;
      end
      'h0c: begin
        csr_rdata_o = {17'h10000, cfg.weights};
        valid_write = data_range_ok(csr_wdata_i, 1);
      end
      'h10: begin
        csr_rdata_o = {17'h10000, cfg.dst};
        valid_write = data_range_ok(csr_wdata_i, 4) && (quant_pack_i || csr_wdata_i[1:0] == 0);
      end
      'h14: begin
        csr_rdata_o = {17'b0, cfg.row_stride};
        valid_write = csr_wdata_i >= 1 && csr_wdata_i <= 32767;
      end
      'h18: begin
        csr_rdata_o = {17'h10000, cfg.partial};
        valid_write = is_rf_address(csr_wdata_i) && data_range_ok(csr_wdata_i, 32) &&
            csr_wdata_i[1:0] == 0;
      end
      'h1c: begin
        csr_rdata_o = {23'b0, cfg.ci};
        valid_write = csr_wdata_i >= 1 && csr_wdata_i <= 256;
      end
      'h20: begin
        csr_rdata_o = cfg.step2 ? 2 : 1;
        valid_write = csr_wdata_i == 1 || csr_wdata_i == 2;
      end
      'h24: begin
        csr_rdata_o = {17'b0, cfg.plane_stride};
        valid_write = csr_wdata_i >= 1 && csr_wdata_i <= 32767;
      end
      'h28: csr_rdata_o = command;
      'h2c: begin
        csr_rdata_o = {24'b0, cfg.offset};
        valid_write = csr_wdata_i <= 255;
      end
      'h30: begin
        csr_rdata_o = 0;
        valid_write = csr_wdata_i == 0 || csr_wdata_i == 2;
      end
      'h40, 'h64: begin
        csr_rdata_o = total_cycles;
        writable = 0;
      end
      'h44, 'h68: begin
        csr_rdata_o = total_macs;
        writable = 0;
      end
      'h54: begin
        csr_rdata_o = 32'h53443931;
        writable = 0;
      end
      'h58: begin
        csr_rdata_o = (QUEUE_DEPTH << 16) | 32'(qcount);
        writable = 0;
      end
      'h5c: begin
        csr_rdata_o = completed;
        writable = 0;
      end
      'h60: begin
        csr_rdata_o = submitted;
        writable = 0;
      end
      'h6c: begin
        csr_rdata_o = 9;
        writable = 0;
      end
      'h70: begin
        csr_rdata_o = 32'h00080020;
        writable = 0;
      end
      default: known = 0;
    endcase
    csr_error_o=(csr_we_i && csr_addr_i=='h30 && csr_wdata_i!=0) || csr_addr_i[1:0]!=0 || !known || (csr_we_i &&
      (!writable || !valid_write ||
       ((blocked_i || pending_i) && !busy_o) ||
       (csr_addr_i!=0 && csr_addr_i!='h28 && busy_o) ||
       (csr_addr_i==0 && csr_wdata_i[0] && (fault || (qcount==QUEUE_DEPTH && !start_o)))));
  end
  always_ff @(posedge clk_i) if (push) queue[tail] <= command;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      cfg <= '0;
      command <= 0;
      head <= 0;
      tail <= 0;
      qcount <= 0;
      fault <= 0;
      done_o <= 0;
      completed <= 0;
      submitted <= 0;
      total_cycles <= 0;
      total_macs <= 0;
    end else begin
      if (events_i.busy) total_cycles <= total_cycles + 1'b1;
      if (events_i.mac_valid) total_macs <= total_macs + 32'(events_i.macs);
      if (events_i.done && !events_i.fault) completed <= completed + 1'b1;
      if (push) begin
        tail <= advance(tail);
        submitted <= submitted + 1'b1;
      end
      if (start_o) head <= advance(head);
      case ({
        push, start_o
      })
        2'b10: qcount <= qcount + 1'b1;
        2'b01: qcount <= qcount - 1'b1;
        default: ;
      endcase
      if (csr_req_i && csr_we_i && !csr_error_o)
        case (csr_addr_i)
          0: begin
            if (csr_wdata_i[1]) begin
              fault <= 0;
              done_o <= 0;
            end
            if (csr_wdata_i[3]) done_o <= 0;
            if (csr_wdata_i[0]) begin
              done_o <= 0;
              if (!valid_command) fault <= 1;
            end
          end
          'h08: cfg.src <= csr_wdata_i[14:0];
          'h0c: cfg.weights <= csr_wdata_i[14:0];
          'h10: cfg.dst <= csr_wdata_i[14:0];
          'h14: cfg.row_stride <= csr_wdata_i[14:0];
          'h18: cfg.partial <= csr_wdata_i[14:0];
          'h1c: cfg.ci <= csr_wdata_i[8:0];
          'h20: cfg.step2 <= csr_wdata_i == 2;
          'h24: cfg.plane_stride <= csr_wdata_i[14:0];
          'h28: command <= csr_wdata_i;
          'h2c: cfg.offset <= csr_wdata_i[7:0];
          default: ;
        endcase
      // Set-dominant done acknowledgement: a new event must remain pending.
      if (events_i.done && !events_i.fault) done_o <= 1;
      if (events_i.fault) begin
        fault <= 1;
        done_o <= 0;
        head <= 0;
        tail <= 0;
        qcount <= 0;
      end
    end
endmodule
