// One serial worker avoids expanding nested timed tasks at every TB call site.
// Requests still traverse the real external TAP/DMI/SBA; no hierarchical access.
  bit jt_request=0,jt_done=0;
  logic[2:0] jt_op;
  logic[31:0] jt_addr,jt_data,jt_result;
  task automatic jt_tick(input bit ms,di,output bit sample);
    tck=0;tms=ms;tdi=di;#20;sample=tdo;tck=1;#20;
  endtask
  task automatic jt_idle(input integer n);
    bit unused_sample;
    repeat(n)jt_tick(0,0,unused_sample);
  endtask
  task automatic jt_ir(input logic[4:0] ir);
    bit s;
    jt_tick(1,0,s);jt_tick(1,0,s);jt_tick(0,0,s);jt_tick(0,0,s);
    for(integer k=0;k<5;k++)jt_tick(k==4,ir[k],s);
    jt_tick(1,0,s);jt_tick(0,0,s);
  endtask
  task automatic jt_dr(input integer n,input logic[40:0] tx,output logic[40:0] rx);
    bit s;
    jt_tick(1,0,s);jt_tick(0,0,s);jt_tick(0,0,s);rx=0;
    for(integer k=0;k<n;k++)begin jt_tick(k==n-1,tx[k],s);rx[k]=s;end
    jt_tick(1,0,s);jt_tick(0,0,s);
  endtask
  task automatic jt_dmi(input bit wr,input logic[6:0] addr,input logic[31:0] data,output logic[31:0] result);
    logic[40:0] response;
    jt_dr(41,{addr,data,wr?2'b10:2'b01},response);jt_idle(64);jt_dr(41,0,response);
    if(response[1:0]!=0)$fatal(1,"DMI operation failed %h",response);
    result=response[33:2];
  endtask
  task automatic jt_wait;
    logic[31:0] status;
    for(integer k=0;k<200;k++)begin
      jt_dmi(0,7'h38,0,status);
      if(status&32'h407000)$fatal(1,"SBA error %h",status);
      if(!status[21])return;
    end
    $fatal(1,"SBA timeout");
  endtask
  initial forever begin:jt_worker
    logic[31:0] unused_word;
    logic[40:0] response;
    bit s;
    wait(jt_request!=jt_done);
    case(jt_op)
      0:jt_dmi(1,jt_addr[6:0],jt_data,jt_result);
      1:jt_dmi(0,jt_addr[6:0],0,jt_result);
      2:begin
        jt_dmi(1,7'h38,32'h40000,unused_word);jt_dmi(1,7'h39,jt_addr,unused_word);
        jt_dmi(1,7'h3c,jt_data,unused_word);jt_wait();jt_result=0;
      end
      3:begin
        jt_dmi(1,7'h38,32'h140000,unused_word);jt_dmi(1,7'h39,jt_addr,unused_word);
        jt_wait();jt_dmi(0,7'h3c,0,jt_result);
      end
      4:begin
        repeat(6)jt_tick(1,0,s);jt_tick(0,0,s);jt_ir(5'h01);jt_dr(32,0,response);
        jt_result=response[31:0];jt_ir(5'h11);
      end
      5:begin jt_wait();jt_result=0;end
      6:begin jt_idle(jt_data);jt_result=0;end
      default:$fatal(1,"Unknown JTAG worker operation");
    endcase
    jt_done=jt_request;
  end
  task automatic jt_send(input logic[2:0] op,input logic[31:0] addr,data,output logic[31:0] result);
    jt_op=op;jt_addr=addr;jt_data=data;jt_request=~jt_request;
    wait(jt_done==jt_request);result=jt_result;
  endtask
  task automatic init_tap(output logic[31:0] idcode);jt_send(4,0,0,idcode);endtask
  task automatic dmi_write(input logic[6:0] addr,input logic[31:0] data);
    logic[31:0] unused_word;jt_send(0,{25'd0,addr},data,unused_word);
  endtask
  task automatic dmi_read(input logic[6:0] addr,output logic[31:0] data);jt_send(1,{25'd0,addr},0,data);endtask
  task automatic sba_write(input logic[31:0] addr,data);
    logic[31:0] unused_word;jt_send(2,addr,data,unused_word);
  endtask
  task automatic sba_read(input logic[31:0] addr,output logic[31:0] data);jt_send(3,addr,0,data);endtask
  task automatic wait_sba;logic[31:0] unused_word;jt_send(5,0,0,unused_word);endtask
  task automatic idle_ticks(input integer n);logic[31:0] unused_word;jt_send(6,0,n,unused_word);endtask
