  task automatic tick(input bit ms, input bit di, output bit sample);
    tck=0; tms=ms; tdi=di; #20; sample=tdo; tck=1; #20;
  endtask
  task automatic idle_ticks(input integer n);
    bit discard_local;
    repeat(n) tick(0,0,discard_local);
  endtask
  task automatic select_ir(input logic [4:0] ir);
    bit discard_local;
    tick(1,0,discard_local); tick(1,0,discard_local); tick(0,0,discard_local); tick(0,0,discard_local);
    for (integer j=0;j<5;j++) tick(j==4,ir[j],discard_local);
    tick(1,0,discard_local); tick(0,0,discard_local);
  endtask
  task automatic scan_dr(input integer n, input logic [40:0] tx, output logic [40:0] rx);
    bit sample;
    tick(1,0,sample); tick(0,0,sample); tick(0,0,sample); rx=0;
    for (integer j=0;j<n;j++) begin tick(j==n-1,tx[j],sample); rx[j]=sample; end
    tick(1,0,sample); tick(0,0,sample);
  endtask
  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,data,2'b10},response); idle_ticks(64); scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI write failed addr=%h status=%h",addr,response[1:0]);
  endtask
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    logic [40:0] response;
    scan_dr(41,{addr,32'd0,2'b01},response); idle_ticks(64); scan_dr(41,41'd0,response);
    if (response[1:0] != 0) $fatal(1,"DMI read failed addr=%h status=%h",addr,response[1:0]);
    data=response[33:2];
  endtask
  task automatic wait_sba;
    logic [31:0] status;
    for (integer j=0;j<40;j++) begin
      dmi_read(7'h38,status);
      if (status[14:12] || status[22]) $fatal(1,"SBA error %h",status);
      if (!status[21]) return;
    end
    $fatal(1,"SBA timeout");
  endtask
  task automatic sba_write(input logic [31:0] addr, input logic [31:0] data);
    dmi_write(7'h38,32'h00040000); dmi_write(7'h39,addr); dmi_write(7'h3c,data); wait_sba();
  endtask
  task automatic sba_read(input logic [31:0] addr, output logic [31:0] data);
    dmi_write(7'h38,32'h00140000); dmi_write(7'h39,addr); wait_sba(); dmi_read(7'h3c,data);
  endtask
