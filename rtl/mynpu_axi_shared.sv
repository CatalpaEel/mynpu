// Single-outstanding AXI4 slave with elastic memory completion. Supports INCR
// and FIXED bursts; unsupported WRAP/oversize transactions return SLVERR.
// AW and W are independent; R/B payloads remain stable during backpressure.
module mynpu_axi_shared #(parameter integer ID_WIDTH=4)(
  input logic clk_i,rst_ni,
  AXI_BUS.Slave slave,
  output logic req_o,we_o,
  output logic[31:0] addr_o,wdata_o,
  output logic[3:0] be_o,
  input logic gnt_i,rvalid_i,
  input logic[31:0] rdata_i,
  input logic error_i
);
  typedef enum logic[2:0] {IDLE,WDATA,REQUEST,WAIT_RESPONSE,RRESP,BRESP} state_t;
  state_t state_q;
  logic write_q,bad_q,last_q,prefer_write_q;
  logic[ID_WIDTH-1:0] id_q;
  logic[31:0] addr_q,data_q,response_q;
  logic[3:0] be_q;
  logic[7:0] remain_q;
  logic[2:0] size_q;
  logic[1:0] burst_q;
  logic response_error_q;
  always_comb begin
    slave.aw_ready=0;slave.w_ready=0;slave.ar_ready=0;
    slave.r_valid=(state_q==RRESP);slave.r_data=response_q;
    slave.r_resp=response_error_q?2'b10:2'b00;slave.r_last=(remain_q==0);
    slave.r_id=id_q;slave.r_user='0;
    slave.b_valid=(state_q==BRESP);slave.b_resp=response_error_q?2'b10:2'b00;
    slave.b_id=id_q;slave.b_user='0;
    if(state_q==IDLE)begin
      // Alternate channel priority. Continuous CPU fetch/read traffic must not
      // starve SBA command/input writes into the same shared AXI target.
      slave.ar_ready=!prefer_write_q||!slave.aw_valid;
      slave.aw_ready=prefer_write_q||!slave.ar_valid;
    end
    if(state_q==WDATA)slave.w_ready=1;
    req_o=(state_q==REQUEST)&&!bad_q;
    we_o=write_q;addr_o=addr_q;wdata_o=data_q;be_o=be_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin
      state_q<=IDLE;write_q<=0;bad_q<=0;last_q<=0;prefer_write_q<=0;id_q<=0;addr_q<=0;
      data_q<=0;be_q<=0;response_q<=0;response_error_q<=0;remain_q<=0;size_q<=0;burst_q<=0;
    end else case(state_q)
      IDLE:if(slave.ar_valid&&slave.ar_ready)begin
        prefer_write_q<=1;
        write_q<=0;id_q<=slave.ar_id;addr_q<=slave.ar_addr;remain_q<=slave.ar_len;
        size_q<=slave.ar_size;burst_q<=slave.ar_burst;
        bad_q<=(slave.ar_size>2)||(slave.ar_burst>1);
        response_error_q<=0;state_q<=REQUEST;
      end else if(slave.aw_valid&&slave.aw_ready)begin
        prefer_write_q<=0;
        write_q<=1;id_q<=slave.aw_id;addr_q<=slave.aw_addr;remain_q<=slave.aw_len;
        size_q<=slave.aw_size;burst_q<=slave.aw_burst;
        bad_q<=(slave.aw_size>2)||(slave.aw_burst>1);
        response_error_q<=0;state_q<=WDATA;
      end
      WDATA:if(slave.w_valid)begin
        data_q<=slave.w_data;be_q<=slave.w_strb;last_q<=slave.w_last;
        if(slave.w_last!=(remain_q==0))response_error_q<=1;
        state_q<=REQUEST;
      end
      REQUEST:if(bad_q)begin
        response_q<=0;response_error_q<=1;
        if(!write_q)state_q<=RRESP;
        else if(remain_q==0)state_q<=BRESP;
        else begin remain_q<=remain_q-1;state_q<=WDATA;end
      end else if(gnt_i)state_q<=WAIT_RESPONSE;
      WAIT_RESPONSE:if(rvalid_i)begin
        response_q<=rdata_i;response_error_q<=response_error_q||error_i;
        if(!write_q)state_q<=RRESP;
        else if(remain_q==0)state_q<=BRESP;
        else begin
          remain_q<=remain_q-1;
          if(burst_q==1)addr_q<=addr_q+(32'd1<<size_q);
          state_q<=WDATA;
        end
      end
      RRESP:if(slave.r_ready)begin
        if(remain_q==0)state_q<=IDLE;
        else begin
          remain_q<=remain_q-1;if(burst_q==1)addr_q<=addr_q+(32'd1<<size_q);
          state_q<=REQUEST;
        end
      end
      BRESP:if(slave.b_ready)state_q<=IDLE;
      default:state_q<=IDLE;
    endcase
  end
endmodule
