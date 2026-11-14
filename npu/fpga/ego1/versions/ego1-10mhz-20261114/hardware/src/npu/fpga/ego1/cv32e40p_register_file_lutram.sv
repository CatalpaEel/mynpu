// Optional FPGA-only implementation; ASIC keeps its original flip-flop RF.
// Two single-write banks and a live-value table implement two-write priority.
module cv32e40p_register_file #(
  parameter ADDR_WIDTH=6, DATA_WIDTH=32, FPU=0, ZFINX=0
) (
  input logic clk, rst_n, scan_cg_en_i,
  input logic [ADDR_WIDTH-1:0] raddr_a_i, raddr_b_i, raddr_c_i,
  output logic [DATA_WIDTH-1:0] rdata_a_o, rdata_b_o, rdata_c_o,
  input logic [ADDR_WIDTH-1:0] waddr_a_i,
  input logic [DATA_WIDTH-1:0] wdata_a_i,
  input logic we_a_i,
  input logic [ADDR_WIDTH-1:0] waddr_b_i,
  input logic [DATA_WIDTH-1:0] wdata_b_i,
  input logic we_b_i
);
  localparam N=1<<(ADDR_WIDTH-1);
  (* ram_style="distributed" *) logic [DATA_WIDTH-1:0] bank_a[N], bank_b[N];
  logic [N-1:0] valid, last_b;
  wire [ADDR_WIDTH-2:0] ia=waddr_a_i[ADDR_WIDTH-2:0], ib=waddr_b_i[ADDR_WIDTH-2:0];
  wire wa=we_a_i && !waddr_a_i[ADDR_WIDTH-1] && ia!=0;
  wire wb=we_b_i && !waddr_b_i[ADDR_WIDTH-1] && ib!=0;
  initial if(FPU!=0 || ADDR_WIDTH!=6) $fatal(1,"Probe supports the current RV32 integer configuration only");
  always_ff @(posedge clk) begin
    if(rst_n && wa) bank_a[ia]<=wdata_a_i;
    if(rst_n && wb) bank_b[ib]<=wdata_b_i;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin valid<='0;last_b<='0;end
    else begin
      if(wa) begin valid[ia]<=1'b1;last_b[ia]<=1'b0;end
      if(wb) begin valid[ib]<=1'b1;last_b[ib]<=1'b1;end
    end
  end
  function automatic logic [DATA_WIDTH-1:0] read_word(input logic [ADDR_WIDTH-1:0] address);
    logic [ADDR_WIDTH-2:0] index;
    index=address[ADDR_WIDTH-2:0];
    if(address[ADDR_WIDTH-1] || index==0 || !valid[index]) return '0;
    return last_b[index] ? bank_b[index] : bank_a[index];
  endfunction
  always_comb begin
    rdata_a_o=read_word(raddr_a_i);
    rdata_b_o=read_word(raddr_b_i);
    rdata_c_o=read_word(raddr_c_i);
  end
endmodule
