`timescale 1ns/1ps
module tb_torus #(parameter CACHE_WORDS=32);
`ifdef ASIC_SRAM
 localparam BACKEND=2;
`else
 localparam BACKEND=1;
`endif
 logic clk=0,rst=0,req=0,we=0,valid=0;
 logic[31:0]addr=0,wd=0,command_word=0,rd;
 logic[3:0]be=15;
 wire gnt,rv,err,ready,irq;
 integer checks=0,cycles=0,io_transfers=0;
 mynpu_torus_subsystem #(.MEM_BACKEND(BACKEND),.STREAM_CACHE_WORDS(CACHE_WORDS)) dut(.clk_i(clk),.rst_ni(rst),.req_i(req),.we_i(we),
 .addr_i(addr),.wdata_i(wd),.be_i(be),.gnt_o(gnt),.rvalid_o(rv),.error_o(err),.rdata_o(rd),
 .command_valid_i(valid),.command_word_i(command_word),.command_ready_o(ready),.irq_o(irq),
 .host_write_o(),.host_addr_o(),.host_wdata_o(),.host_be_o());
 always #5 clk=~clk;
 always @(posedge clk)begin cycles++;if(cycles>300000)$fatal(1,"timeout");end
 always @(posedge clk)if(rst)io_transfers+=$countones(dut.io_req&dut.gnt[2:1]);
 function automatic logic[31:0] cmd(input integer op,dst,sa,sb,mask);
   cmd=(op<<26)|(dst<<24)|(sa<<19)|(sb<<14)|(mask<<10);
 endfunction
 function automatic logic[31:0] imm(input integer op,dst,sa,value,mask);
   imm=cmd(op,dst,sa,0,mask)|512|(value&511);
 endfunction
 task automatic check(input logic[31:0]got,expected,input string label);
   checks++;if(got!==expected)$fatal(1,"%s got=%h expected=%h check=%0d",label,got,expected,checks);
 endtask
 task automatic host(input logic wr,input logic[31:0]a,v,input logic[3:0]bytes,output logic[31:0]result);
   @(negedge clk);req=1;we=wr;addr=a;wd=v;be=bytes;
   do @(posedge clk);while(!gnt);
   @(negedge clk);req=0;
   while(!rv)@(negedge clk);
   if(err)$fatal(1,"host error %h",a);
   result=rd;
 endtask
 task automatic put(input logic[31:0]a,v);logic[31:0]dummy;host(1,a,v,15,dummy);endtask
 task automatic expect_at(input logic[31:0]a,v);logic[31:0]r;host(0,a,0,15,r);check(r,v,$sformatf("addr %h",a));endtask
 task automatic emit(input logic[31:0]v);
   @(negedge clk);command_word=v;valid=1;
   do @(posedge clk);while(!ready);
   @(negedge clk);valid=0;
 endtask
 task automatic wait_io;
   integer n;logic[31:0]r;
   n=0;
   do begin host(0,32'h70000004,0,15,r);n++;if(n>1000)$fatal(1,"io timeout");end while(r[0]);
 endtask
 task automatic descriptor(input integer c,base,ctl,nr,nc,rs,cs,n0,n1,n2,s0,s1,s2,regsteps,origin);
   logic[31:0]d[0:12];
   d[0]=base;d[1]=ctl;d[2]=nr|(nc<<4);d[3]=rs;d[4]=cs;d[5]=n0;d[6]=n1;d[7]=n2;
   d[8]=s0;d[9]=s1;d[10]=s2;d[11]=regsteps;d[12]=origin;
   for(integer j=0;j<13;j++)put(32'h70000400+c*256+j*4,d[j]);
 endtask
 task automatic next_tile(input integer contexts,rows);
   emit(cmd(62,0,0,0,rows)|contexts);wait_io();
 endtask
 logic[31:0]value,r;
 logic signed[63:0]product;
 integer neighbor,mask,dest,src_reg,dir,fmt,bytes,n0,n1,n2,address;
 initial begin
   repeat(4)@(negedge clk);rst=1;
   expect_at(32'h70000000,32'h544f5204);
   for(integer p=0;p<16;p++)for(integer k=0;k<4;k++)begin
     value=p*100+k+1;put(32'h70000100+p*16+k*4,value);
   end
   // Every direction and every source register, independently on both inputs.
   // Compare ALL registers: masks, local-only destinations and simultaneity.
   for(dir=1;dir<=4;dir++)for(src_reg=0;src_reg<4;src_reg++)begin
     dest=(src_reg+1)%4;mask=(dir&1)?5:10;
     for(integer p=0;p<16;p++)for(integer k=0;k<4;k++)begin
       put(32'h70000100+p*16+k*4,p*100+k+1);
     end
     emit(cmd(3,dest,dir*4+src_reg,((dir%4)+1)*4+(src_reg+2)%4,mask));
     for(integer p=0;p<16;p++)begin
       integer a,b;
       case(dir)1:a=((p/4+3)%4)*4+p%4;2:a=((p/4+1)%4)*4+p%4;3:a=p/4*4+(p%4+3)%4;4:a=p/4*4+(p%4+1)%4;endcase
       case((dir%4)+1)1:b=((p/4+3)%4)*4+p%4;2:b=((p/4+1)%4)*4+p%4;3:b=p/4*4+(p%4+3)%4;4:b=p/4*4+(p%4+1)%4;endcase
       for(integer k=0;k<4;k++)expect_at(32'h70000100+p*16+k*4,(mask[p/4]&&k==dest)?a*100+src_reg+1+b*100+(src_reg+2)%4+1:p*100+k+1);
     end
   end
   // Sustained issue: one command on every edge for 64 clocks, local writes.
   emit(imm(2,0,0,0,15));
   @(negedge clk);valid=1;command_word=imm(3,0,0,1,15);
   repeat(64)begin @(posedge clk);check(ready,1,"one command/cycle");end
   @(negedge clk);valid=0;
   for(integer p=0;p<16;p++)expect_at(32'h70000100+p*16,64);
   // Generic quantization primitive: exact fixed point rounding, negative ties.
   for(integer j=0;j<80;j++)begin
     logic[31:0]a,b,expected;
     a=$random;b=$random;
     put(32'h70000100,a);put(32'h70000104,b);
     product=$signed(a)*$signed(b);expected=product[63:32]+product[31];
     emit(cmd(51,2,0,1,1));expect_at(32'h70000108,expected);
   end
   // Signed 8/16/32 multiply and accumulating in the SELECTED destination.
   for(integer j=0;j<30;j++)begin
     logic signed[31:0]a,b,ea,eb;
     a=$random;b=$random;
     for(integer precision=0;precision<3;precision++)begin
       ea=(precision==0)?$signed(a[7:0]):((precision==1)?$signed(a[15:0]):a);
       eb=(precision==0)?$signed(b[7:0]):((precision==1)?$signed(b[15:0]):b);
       put(32'h70000100,a);put(32'h70000104,b);put(32'h7000010c,123);
       emit(cmd(22+precision*2,3,0,1,1));expect_at(32'h7000010c,ea*eb+123);
     end
   end
   // Equivalent shared shifter: every shift amount, signed extrema, ties,
   // both rotations, and independent scalar reference bit-count algorithms.
   for(integer j=0;j<16;j++)begin
     logic[31:0]a,expected;
     logic signed[32:0]rounded;
     integer op,zeros,ones;
     case(j)
       0:a=0;1:a=1;2:a='hffffffff;3:a='h7fffffff;
       4:a='h80000000;5:a='h40000000;6:a='hc0000000;
       7:a='h12345678;default:a=$random;
     endcase
     put('h70000100,a);
     for(integer which=0;which<3;which++)begin
       expected=0;
       if(which==2)begin for(integer k=0;k<32;k++)expected+=a[k];end
       else begin
         expected=32;
         for(integer k=31;k>=0;k--)if(which?a[k]:a[31-k])expected=k;
       end
       emit(cmd(40+which,2,0,1,1));expect_at('h70000108,expected);
     end
     for(integer sh=0;sh<32;sh++)begin
       put('h70000104,sh);
       for(integer which=0;which<6;which++)begin
         case(which)0:op=10;1:op=11;2:op=12;3:op=38;4:op=39;5:op=43;endcase
         case(op)
           10:expected=a<<sh;11:expected=a>>sh;12:expected=$signed(a)>>>sh;
           38:expected=sh?((a<<sh)|(a>>(32-sh))):a;
           39:expected=sh?((a>>sh)|(a<<(32-sh))):a;
           43:begin rounded=$signed({a[31],a});if(sh)rounded=rounded+(33'sd1<<(sh-1));expected=rounded>>>sh;end
         endcase
         emit(cmd(op,2,0,1,1));expect_at('h70000108,expected);
       end
     end
   end
   for(integer j=0;j<512;j++)put(32'h80002000+j*4,{8'(j*4+3),8'(j*4+2),8'(j*4+1),8'(j*4)});
   // Read signed bytes into R3, column broadcast to all four rows.
   descriptor(0,'h2080,1+32,4,4,0,1,1,1,1,0,0,0,3,0);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
   for(integer p=0;p<16;p++)expect_at('h7000010c+p*16,32'hffffff80+p%4);
   // Three outer axes, negative/zero strides, rotating destination registers.
   descriptor(0,'h210c,0+16,4,4,1,0,2,3,2,-4,16,0,0|(1<<2)|(2<<4)|(3<<6),0);
   emit(cmd(61,0,0,0,0)|1);
   for(n2=0;n2<2;n2++)for(n1=0;n1<3;n1++)for(n0=0;n0<2;n0++)begin
     next_tile(1,15);address='h210c-n0*4+n1*16;dest=(n0+2*n1+3*n2)%4;
     for(integer p=0;p<16;p++)expect_at('h70000100+p*16+dest*4,(address-'h2000+p/4)&255);
   end
   check(dut.ended[0],1,"outer shape ended");
   // A conflict gather (all four words same cache index) must make progress.
   for(integer k=0;k<4;k++)put('h80002200+k*CACHE_WORDS*4,'h12340000+k);
   descriptor(0,'h2200,4+32,4,4,0,CACHE_WORDS*4,1,1,1,0,0,0,2,0);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
   for(integer p=0;p<16;p++)expect_at('h70000108+p*16,32'h12340000+p%4);
   // Host writes invalidate cached words, with identical descriptor reuse.
   put('h80002200,'h12345678);emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
   expect_at('h70000108,'h12345678);
   // Warm same-bank/different-row hits replay without rereading SRAM.
   // A host write invalidates only its matching word, not the other rows.
   begin
     integer before_io;
     for(integer k=0;k<4;k++)put('h80002400+k*16,'h71350000+k);
     descriptor(0,'h2400,4+32,4,4,0,16,1,1,1,0,0,0,2,0);
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
     before_io=io_transfers;emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
     check(io_transfers,before_io,"bank-conflicting warm hits issue no SRAM reads");
     for(integer p=0;p<16;p++)expect_at('h70000108+p*16,'h71350000+p%4);
     put('h80002420,'habcdef01);before_io=io_transfers;
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
     check(io_transfers,before_io+1,"exact invalidation retains other bank rows");
     for(integer p=0;p<16;p++)expect_at('h70000108+p*16,(p%4==2)?'habcdef01:('h71350000+p%4));
   end
   // Full tile transpose and byte/halfword/word stores; neighbors preserved.
   for(fmt=0;fmt<3;fmt++)begin
     bytes=1<<fmt;
     for(integer p=0;p<16;p++)put('h70000104+p*16,'h12340080+p);
     for(integer j=0;j<20;j++)put('h80002600+j*4,'ha5a5a5a5);
     descriptor(1,'h2600,8+64+((fmt==0)?0:((fmt==1)?2:4)),4,4,bytes,4*bytes,1,1,1,0,0,0,1,0);
     emit(cmd(61,0,0,0,0)|2);next_tile(2,15);
     descriptor(0,'h2600,64+((fmt==0)?0:((fmt==1)?2:4)),4,4,bytes,4*bytes,1,1,1,0,0,0,2,0);
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
     for(integer p=0;p<16;p++)expect_at('h70000108+p*16,('h12340080+p)&((fmt==2)?32'hffffffff:((1<<(8*bytes))-1)));
     expect_at('h80002600+16*bytes,'ha5a5a5a5);
   end
   // Concurrent ports and two contexts sharing one port; independent R targets.
   descriptor(0,'h2000,32,4,4,0,1,1,1,1,0,0,0,0,0);
   descriptor(1,'h2004,32,4,4,0,1,1,1,1,0,0,0,1,0);
   descriptor(2,'h2008,32,4,4,0,1,1,1,1,0,0,0,2,0);
   emit(cmd(61,0,0,0,0)|7);next_tile(7,15);
   for(integer p=0;p<16;p++)for(integer k=0;k<3;k++)expect_at('h70000100+p*16+k*4,p%4+k*4);
   // Signed halfwords, torus tile origin and physical row mask.
   put('h80002080,'h80007fff);
   for(integer p=0;p<16;p++)put('h70000104+p*16,'h5aa5);
   descriptor(0,'h2080,3+32,3,2,0,2,1,1,1,0,0,0,1,15);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,9);
   for(integer p=0;p<16;p++)begin
     value='h5aa5;
     if((p/4==0||p/4==3)&&p%4==3)value='h7fff;
     if((p/4==0||p/4==3)&&p%4==0)value='hffff8000;
     expect_at('h70000104+p*16,value);
   end
   // Debug byte enables address one local register, preserving its other bytes.
   put('h70000100,'habcdef12);host(1,'h70000100,'h00aa0000,4,r);
   expect_at('h70000100,'habaaef12);
   // Outer cyclic mode and register selection wrap around after the shape.
   descriptor(0,'h2000,256+32,4,4,0,1,2,1,1,4,0,0,3|(1<<2),0);
   emit(cmd(61,0,0,0,0)|1);
   for(integer j=0;j<5;j++)begin
     next_tile(1,15);dest=(j%2==0)?3:0;
     for(integer p=0;p<16;p++)expect_at('h70000100+p*16+dest*4,p%4+(j%2)*4);
   end
   check(dut.ended[0],0,"cyclic context not ended");
   // Software pipeline: gather next operands while computing current ones.
   for(integer p=0;p<16;p++)put('h70000100+p*16,0);
   put('h80002800,2);put('h80002804,5);put('h80002808,7);put('h8000280c,9);
   put('h80002840,3);put('h80002844,11);put('h80002848,13);put('h8000284c,17);
   descriptor(0,'h2800,4+16,4,4,0,0,4,1,1,4,0,0,2,0);
   descriptor(1,'h2840,4+32,4,4,0,0,4,1,1,4,0,0,3,0);
   emit(cmd(61,0,0,0,0)|3);next_tile(3,15);
   emit(cmd(60,0,0,0,5)|3);
   emit(cmd(26,0,2,3,15));
   // Prefetched data must stay outside the PE register file until COMMIT.
   expect_at('h70000108,2);expect_at('h7000010c,3);expect_at('h70000100,6);
   emit(cmd(58,0,0,0,10)|3);emit(cmd(26,0,2,3,5));
   emit(cmd(58,0,0,0,15)|3);emit(cmd(26,0,2,3,10));
   emit(cmd(59,0,0,0,0)|3);emit(cmd(26,0,2,3,15));wait_io();
   for(integer p=0;p<16;p++)begin
     expect_at('h70000100+p*16,((p/4)%2==0)?214:250);
     expect_at('h70000108+p*16,9);expect_at('h7000010c+p*16,17);
   end
   host(0,'h70000018,0,15,r);checks++;if(r==0)$fatal(1,"No PE execution during active prefetch");
   // One 32-bit word executes an ALU op using OLD operands, publishes the
   // buffered NEXT operands, and optionally starts another prefetch.
   for(integer p=0;p<16;p++)put('h70000100+p*16,0);
   descriptor(0,'h2800,4+16,4,4,0,0,3,1,1,4,0,0,2,0);
   descriptor(1,'h2840,4+32,4,4,0,0,3,1,1,4,0,0,3,0);
   emit(cmd(61,0,0,0,0)|3);next_tile(3,15);emit(cmd(60,0,0,0,15)|3);
   emit(cmd(26,0,2,3,15)|'h1cf); // MAC0 + commit1 + prefetch2
   emit(cmd(26,0,2,3,15)|'h140); // MAC1 + commit2, no overrun
   emit(cmd(26,0,2,3,15));wait_io();
   for(integer p=0;p<16;p++)expect_at('h70000100+p*16,152);
   // Bundle WAW faults without publishing either arithmetic or loaded data.
   emit(cmd(61,0,0,0,0)|1);emit(cmd(60,0,0,0,15)|1);
   emit(cmd(1,2,0,0,15)|'h100);check(irq,1,"bundle destination conflict");
   emit(cmd(59,0,0,0,0)|1);put('h70000010,1);
   // A blocked host config write cannot starve direct CPU COMMIT (deadlock).
   emit(cmd(61,0,0,0,0)|1);emit(cmd(60,0,0,0,15)|1);
   fork
     put('h70000400,'h2804);
     emit(cmd(59,0,0,0,0)|1);
   join
   wait_io();expect_at('h70000108,2);expect_at('h70000400,'h2804);
   // Deferred register stepping must commit the completed tile's register,
   // even though its outer cursor has already advanced to the next register.
   put('h70000108,'h123);put('h7000010c,'h456);
   descriptor(0,'h2800,4+16,4,4,0,0,2,1,1,4,0,0,2|(1<<2),0);
   emit(cmd(61,0,0,0,0)|1);emit(cmd(60,0,0,0,15)|1);emit(cmd(59,0,0,0,0)|1);
   expect_at('h70000108,2);expect_at('h7000010c,'h456);
   emit(cmd(60,0,0,0,15)|1);emit(imm(3,0,2,1,15));emit(cmd(59,0,0,0,0)|1);
   expect_at('h70000100,3);expect_at('h70000108,2);expect_at('h7000010c,5);
   // Register scoreboard: independent ALUs can overlap ordinary FULL stores
   // and loads; conflicts include neighbor register reads, RAW and WAW.
   for(integer p=0;p<16;p++)begin put('h70000100+p*16,'haa);put('h70000104+p*16,10);end
   descriptor(1,'h2900,4+8,4,4,64,4,1,1,1,0,0,0,0,0);
   emit(cmd(61,0,0,0,0)|2);emit(cmd(62,0,0,0,15)|2);
   command_word=imm(3,0,0,1,15);#1;check(ready,0,"store read lock blocks overwrite");
   emit(imm(3,1,1,1,15));check(dut.busy,1,"independent ALU overlaps FULL store");wait_io();
   expect_at('h70000104,11);expect_at('h80002900,'haa);expect_at('h800029cc,'haa);
   descriptor(0,'h2900,4,4,4,64,4,1,1,1,0,0,0,2,0);
   emit(cmd(61,0,0,0,0)|1);emit(cmd(62,0,0,0,15)|1);
   command_word=cmd(1,0,14,0,15);#1;check(ready,0,"neighbor RAW hazard blocked");
   command_word=imm(2,2,0,77,15);#1;check(ready,0,"load WAW hazard blocked");
   emit(imm(3,1,1,1,15));check(dut.busy,1,"independent ALU overlaps FULL load");wait_io();
   emit(cmd(1,0,14,0,15));expect_at('h70000100,'haa);expect_at('h70000104,12);
   // Deferred mode deliberately rejects FULL tiles and two contexts per port.
   descriptor(0,'h2800,4,1,1,0,0,1,1,1,0,0,0,2,0);
   emit(cmd(61,0,0,0,0)|1);emit(cmd(60,0,0,0,15)|1);wait_io();
   check(irq,1,"FULL prefetch rejected");put('h70000010,1);
   emit(cmd(60,0,0,0,15)|5);check(irq,1,"same port double prefetch rejected");put('h70000010,1);
   emit(cmd(59,0,0,0,0)|1);check(irq,1,"missing prefetch commit faults without hanging");put('h70000010,1);
   // Generic packed base pair supports different contexts/banks and resets
   // arbitrary selected cursors; it is not tied to a neural-network layer.
   put('h80000100,1234);put('h80000104,5678);
   descriptor(0,0,4+16,1,1,0,0,1,1,1,0,0,0,2,0);
   descriptor(1,0,4+32,1,1,0,0,1,1,1,0,0,0,3,0);
   put('h70000024,'he4); // A=ctx0/bank0, B=ctx1/bank1, ARM ctx0/1
   emit(cmd(53,0,0,0,0)|('h100<<13)|'h800);
   expect_at('h70000400,'h100);expect_at('h70000500,'h2800);next_tile(3,15);
   expect_at('h70000108,1234);expect_at('h7000010c,2);
   emit(cmd(53,0,0,0,0)|('h104<<13)|'h804);next_tile(3,15);
   expect_at('h70000108,5678);expect_at('h7000010c,5);
   put('h70000024,0);emit(cmd(53,0,0,0,0));check(irq,1,"basepair same-context fault");
   expect_at('h70000400,'h104);put('h70000010,1);put('h70000024,'hc4);
   // Invalid operands/opcodes consume a command and fault without RF writes.
   put('h70000100,99);emit(cmd(1,0,20,0,1));check(irq,1,"invalid read source");expect_at('h70000100,99);put('h70000010,1);
   emit(cmd(63,0,0,0,1));check(irq,1,"removed export opcode");expect_at('h70000100,99);put('h70000010,1);
   // Masked negative padding generates no invalid SRAM request.
   descriptor(0,-1,16,4,4,1,0,1,1,1,0,0,0,3,0);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,0);
   check(irq,0,"masked padding");
   // Misaligned 32-bit transfers and out-of-range data raise errors.
   descriptor(0,'h2001,4,1,1,0,0,1,1,1,0,0,0,0,0);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(irq,1,"alignment error");put('h70000010,1);
   descriptor(0,'h4000,0,1,1,0,0,1,1,1,0,0,0,0,0);
   emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(irq,1,"bounds error");put('h70000010,1);
   // Compact descriptors must NEVER alias a rejected wide configuration to
   // low SRAM. Clearing IRQ alone does not repair an invalid field.
   begin
     integer before_io;
     descriptor(0,'h2000,4,1,1,0,0,1,1,1,0,0,0,2,0);
     put('h70000108,'h5678);put('h7000040c,'h10000);
     check(irq,1,"stride outside signed16 rejected");put('h70000010,1);
     before_io=io_transfers;emit(cmd(61,0,0,0,0)|1);next_tile(1,15);
     check(irq,1,"invalid field persists until rewritten");check(io_transfers,before_io,"bad stride no SRAM requests");
     expect_at('h70000108,'h5678);
     put('h7000040c,-1);expect_at('h7000040c,'hffffffff);put('h70000010,1);
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(irq,0,"valid rewrite repairs field");expect_at('h70000108,'h03020100);
     put('h70000400,'h10002000);check(irq,1,"wide base rejected");put('h70000010,1);
     before_io=io_transfers;emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(io_transfers,before_io,"bad base no low alias");
     put('h70000400,'h2000);put('h70000010,1);
     put('h70000414,65536);check(irq,1,"shape outside uint16 rejected");
     put('h70000414,65535);expect_at('h70000414,65535);put('h70000010,1);
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(dut.ended[0],0,"maximum shape remains active");
     // A masked tile may have an out-of-SRAM base; signed16 cursor overflow
     // is sticky until ARM, even if truncated bits later resemble valid RAM.
     descriptor(0,'h7fff,16,1,1,0,0,2,1,1,1,0,0,2,0);
     before_io=io_transfers;emit(cmd(61,0,0,0,0)|1);next_tile(1,0);check(irq,0,"masked tile may advance");
     next_tile(1,0);check(irq,1,"cursor overflow rejected");check(io_transfers,before_io,"overflow no SRAM requests");
     descriptor(0,'h2000,0,1,1,0,0,1,1,1,0,0,0,2,0);put('h70000010,1);
     emit(cmd(61,0,0,0,0)|1);next_tile(1,15);check(irq,0,"ARM clears cursor overflow");
   end
   check(irq,0,"clear error");
   $display("TORUS-PASS backend=%0d checks=%0d cycles=%0d",BACKEND,checks,cycles);$finish;
 end
endmodule
