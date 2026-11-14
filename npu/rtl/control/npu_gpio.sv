// Eight software-controlled pins. DIR=1 drives OUT; reset releases all pins.
// Inputs are independently synchronized: multi-bit atomic sampling requires
// an external handshake. Word MMIO transactions use only the low eight bits.
module npu_gpio (
  input logic clk_i, rst_ni, req_i, we_i,
  input logic [7:0] addr_i,
  input logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic error_o,
  input logic [7:0] gpio_i,
  output logic [7:0] gpio_o, gpio_oe_o
);
  (* ASYNC_REG = "TRUE" *) logic [7:0] input_meta_q, input_sync_q;
  logic known, writable;
  always_comb begin
    rdata_o = 0;
    known = 1;
    writable = 1;
    case (addr_i)
      8'h00: begin rdata_o = {24'b0, input_sync_q}; writable = 0; end
      8'h04: rdata_o = {24'b0, gpio_o};
      8'h08: rdata_o = {24'b0, gpio_oe_o};
      8'h0c, 8'h10, 8'h14: rdata_o = 0; // Atomic OUT set/clear/toggle.
      8'h18: begin rdata_o = 32'h00010008; writable = 0; end
      default: begin known = 0; writable = 0; end
    endcase
    error_o = req_i && (!known || (we_i && !writable));
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      input_meta_q <= 0;
      input_sync_q <= 0;
      gpio_o <= 0;
      gpio_oe_o <= 0;
    end else begin
      input_meta_q <= gpio_i;
      input_sync_q <= input_meta_q;
      if (req_i && we_i && !error_o) begin
        case (addr_i)
          8'h04: gpio_o <= wdata_i[7:0];
          8'h08: gpio_oe_o <= wdata_i[7:0];
          8'h0c: gpio_o <= gpio_o | wdata_i[7:0];
          8'h10: gpio_o <= gpio_o & ~wdata_i[7:0];
          8'h14: gpio_o <= gpio_o ^ wdata_i[7:0];
          default: ;
        endcase
      end
    end
  end
endmodule
