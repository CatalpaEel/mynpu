`timescale 1ns/1ps
// Four logical blocks: CPU interface, shared SRAM, PE torus, shape/stride I/O.
// Both host aliases and stream descriptors use the same bank-linear byte space.
module mynpu_torus_subsystem #(
  parameter integer MEM_BACKEND=1,STREAM_CACHE_WORDS=32,
  parameter BANK0_INIT_FILE="",BANK1_INIT_FILE=""
)(
  input logic clk_i,rst_ni,req_i,we_i,
  input logic[31:0] addr_i,wdata_i,
  input logic[3:0] be_i,
  output logic gnt_o,rvalid_o,error_o,
  output logic[31:0] rdata_o,
  input logic command_valid_i,
  input logic[31:0] command_word_i,
  output logic command_ready_o,
  output logic irq_o,
  output logic host_write_o,
  output logic[31:0] host_addr_o,host_wdata_o,
  output logic[3:0] host_be_o
);
  logic memory_access,register_access,host_accept,host_command,fast_command,command,arithmetic_valid;
  logic response_q,response_error_q,busy,io_error,command_error_q,compute_safe,prefetch_busy;
  logic[31:0] register_data,response_data_q,merged_data,word;
  logic[31:0] command_count_q,busy_count_q,overlap_count_q,descriptor_count_q;
  logic[3:0] ended,buffer_ready,reserved,read_locks,write_locks;
  logic host_writable,exchange_valid,bundle,bundle_bad,flow_start,flow_commit;
  logic[3:0] flow_contexts,flow_rows,incoming;
  logic[7:0] buffer_regs;
  logic[9:0] pair_config_q;
  logic pair_bad;
  logic clear_error,descriptor_write,debug_write;
  wire[31:0] registers[0:15][0:3];
  logic[15:0] load_mask[0:1][0:3];
  logic[31:0] load_data[0:1][0:3];
  logic[1:0] load_reg[0:1];
  logic[31:0] descriptor_data;
  logic[2:0] req,we,gnt,rv;
  logic[13:0] addr[0:2],io_addr[0:1];
  logic[3:0] be[0:2],io_be[0:1];
  logic[31:0] wd[0:2],rd[0:2],io_wd[0:1],io_rd[0:1];
  logic[1:0] io_req,io_we;
  assign memory_access=((addr_i>=32'h80000000)&&(addr_i<32'h80004000))||
                       ((addr_i>=32'h70004000)&&(addr_i<32'h70008000));
  assign register_access=(addr_i>=32'h70000000)&&(addr_i<32'h70001000);
  // Register-format spare bits optionally issue ALU and stream actions on
  // one edge. Reads observe OLD PE data; selected input loads publish after it.
  function automatic logic is_bundle(input logic[31:0]c);
    is_bundle=c[31:26]<=52&&!c[9]&&c[8];
  endfunction
  function automatic logic[3:0] contexts_of(input logic[31:0]c);
    if(!is_bundle(c))contexts_of=c[3:0];
    else case(c[6:4])
      0:contexts_of=1;1:contexts_of=2;2:contexts_of=4;3:contexts_of=8;
      4:contexts_of=3;5:contexts_of=9;6:contexts_of=6;7:contexts_of=12;
    endcase
  endfunction
  function automatic logic[3:0] incoming_registers(input logic[3:0]ctx,ready_mask,input logic[7:0]regs);
    begin
      incoming_registers=0;
      for(integer c=0;c<4;c++)if(ctx[c]&&ready_mask[c])incoming_registers[regs[c*2+:2]]=1;
    end
  endfunction
  function automatic logic can_issue(input logic[31:0]candidate,input logic is_busy,is_safe,
      input logic[3:0]ready_mask,reserved_mask,read_mask,write_mask,input logic[7:0]regs);
    logic[3:0]ctx,loaded_regs;
    logic safe_alu;
    begin
      ctx=contexts_of(candidate);loaded_regs=incoming_registers(ctx,ready_mask,regs);
      safe_alu=!is_busy||!(|candidate[13:10])||
        (!(read_mask[candidate[25:24]]||write_mask[candidate[25:24]])&&
         !write_mask[candidate[20:19]]&&(candidate[9]||!write_mask[candidate[15:14]]));
      if(is_bundle(candidate))begin
        if((|(ctx&~reserved_mask))||(candidate[7]&&ctx!=reserved_mask)||
            ((|candidate[13:10])&&loaded_regs[candidate[25:24]]))can_issue=1;
        else can_issue=(ctx&ready_mask)==ctx&&safe_alu;
      end else case(candidate[31:26])
        58:can_issue=(ctx!=reserved_mask)||(((ctx&ready_mask)==ctx)&&(!is_busy||is_safe));
        59:can_issue=((ctx&ready_mask)==ctx)||(|(ctx&~reserved_mask));
        53,60,61,62:can_issue=!is_busy;
        default:can_issue=candidate[31:26]>52||safe_alu;
      endcase
    end
  endfunction
  assign host_writable=(addr_i[11:0]==12'hffc)?(!(&be_i)||can_issue(wdata_i,busy,compute_safe,buffer_ready,reserved,read_locks,write_locks,buffer_regs)):!busy;
  assign gnt_o=rst_ni&&req_i&&(memory_access?gnt[0]:(!register_access||!we_i||host_writable));
  assign host_accept=req_i&&gnt_o&&register_access&&we_i;
  assign host_command=host_accept&&addr_i[11:0]==12'hffc&&(&be_i);
  // A debug config write held off by a reserved input buffer must not prevent
  // the CPU's direct COMMIT from releasing that buffer.
  assign command_ready_o=rst_ni&&can_issue(command_word_i,busy,compute_safe,buffer_ready,reserved,read_locks,write_locks,buffer_regs)&&!(req_i&&register_access&&we_i&&host_writable);
  assign fast_command=command_valid_i&&command_ready_o;
  assign command=fast_command||host_command;
  // Decode the CPU word before ready, allowing ALU settling while a stream
  // dependency waits. Execution still occurs only on an accepted handshake.
  assign word=host_command?wdata_i:command_word_i;
  assign pair_bad=word[31:26]==53&&pair_config_q[1:0]==pair_config_q[3:2];
  assign bundle=is_bundle(word);
  assign flow_contexts=contexts_of(word);
  assign flow_rows=bundle?word[3:0]:word[13:10];
  assign incoming=incoming_registers(flow_contexts,buffer_ready,buffer_regs);
  assign bundle_bad=bundle&&((|(flow_contexts&~reserved))||(word[7]&&flow_contexts!=reserved)||
    ((|word[13:10])&&incoming[word[25:24]]));
  assign arithmetic_valid=word[31:26]<=52&&word[23:19]<20&&(word[9]||word[18:14]<20)&&!bundle_bad;
  assign flow_start=command&&exchange_valid&&!bundle_bad&&
    (word[31:26]==58||word[31:26]==60||word[31:26]==62||(bundle&&word[7]));
  assign flow_commit=command&&exchange_valid&&!bundle_bad&&(word[31:26]==58||word[31:26]==59||bundle);
  assign exchange_valid=word[31:26]!=58||word[3:0]==reserved;
  assign clear_error=host_accept&&addr_i[11:0]==12'h010&&merged_data[0];
  assign descriptor_write=host_accept&&addr_i[11:10]==1;
  assign debug_write=host_accept&&addr_i[11:8]==1;
  assign irq_o=io_error||command_error_q;
  assign addr[0]={addr_i[12:2],addr_i[13],addr_i[1:0]};
  assign req[0]=req_i&&memory_access;assign we[0]=we_i;assign be[0]=be_i;assign wd[0]=wdata_i;
  for(genvar p=0;p<2;p++)begin:g_port
    assign req[p+1]=io_req[p];assign we[p+1]=io_we[p];
    assign addr[p+1]={io_addr[p][12:2],io_addr[p][13],io_addr[p][1:0]};
    assign be[p+1]=io_be[p];assign wd[p+1]=io_wd[p];assign io_rd[p]=rd[p+1];
  end
  assign host_write_o=req_i&&gnt_o&&we_i&&memory_access;
  assign host_addr_o=addr_i;assign host_wdata_o=wdata_i;assign host_be_o=be_i;
  assign rvalid_o=rv[0]||response_q;assign rdata_o=rv[0]?rd[0]:response_data_q;
  assign error_o=response_q&&response_error_q;
  always_comb begin
    register_data=0;
    case(addr_i[11:0])
      12'h000:register_data=32'h544f5204; // TOR, ABI 4: compact checked 16-bit stream descriptors
      12'h004:register_data={20'd0,buffer_ready,ended,2'd0,irq_o,busy};
      12'h008:register_data=command_count_q;
      12'h00c:register_data=busy_count_q;
      12'h018:register_data=overlap_count_q;
      12'h01c:register_data=descriptor_count_q;
      12'h024:register_data={22'd0,pair_config_q};
      12'h028:register_data=32'h10100e10; // cursor/shape/address-space/stride bits
      12'h014:register_data=32'h04041020; // 4 regs, 4 rows, 16 PEs, 32-bit commands
      default:begin
        if(addr_i[11:8]==1)register_data=registers[addr_i[7:4]][addr_i[3:2]];
        else if(addr_i[11:10]==1)register_data=descriptor_data;
      end
    endcase
    for(integer b=0;b<4;b++)merged_data[b*8+:8]=be_i[b]?wdata_i[b*8+:8]:register_data[b*8+:8];
  end
  always_ff @(posedge clk_i or negedge rst_ni)begin
    if(!rst_ni)begin
      response_q<=0;response_error_q<=0;response_data_q<=0;
      command_count_q<=0;busy_count_q<=0;command_error_q<=0;overlap_count_q<=0;descriptor_count_q<=0;pair_config_q<=10'h0c4;
    end else begin
      response_q<=req_i&&gnt_o&&!memory_access;
      response_error_q<=!register_access;
      if(req_i&&gnt_o&&!memory_access)response_data_q<=register_data;
      if(busy)busy_count_q<=busy_count_q+1;
      if(command&&arithmetic_valid&&(|word[13:10])&&prefetch_busy)overlap_count_q<=overlap_count_q+1;
      if(descriptor_write)descriptor_count_q<=descriptor_count_q+1;
      if(command&&word[31:26]==53&&!pair_bad)descriptor_count_q<=descriptor_count_q+2;
      if(host_accept&&addr_i[11:0]==12'h024)pair_config_q<=merged_data[9:0];
      if(clear_error)command_error_q<=0;
      if(command)begin
        command_count_q<=command_count_q+1;
        if((word[31:26]>53&&(word[31:26]<58||word[31:26]==63))||!exchange_valid||bundle_bad||pair_bad||
           (word[31:26]<=52&&(word[23:19]>=20||(!word[9]&&word[18:14]>=20))))command_error_q<=1;
      end
      if(host_accept&&addr_i[11:0]==12'hffc&&!(&be_i))command_error_q<=1;
    end
  end
  torus_array i_array(.clk_i(clk_i),.rst_ni(rst_ni),.command_i(command&&arithmetic_valid),.command_word_i(word),
    .load_mask_i(load_mask),.load_data_i(load_data),.load_reg_i(load_reg),
    .debug_write_i(debug_write),.debug_pe_i(addr_i[7:4]),
    .debug_reg_i(addr_i[3:2]),.debug_data_i(merged_data),.debug_be_i(be_i),
    .registers_o(registers));
  shape_stream #(.CACHE_WORDS(STREAM_CACHE_WORDS)) i_stream(.clk_i(clk_i),.rst_ni(rst_ni),.cfg_write_i(descriptor_write),
    .cfg_addr_i(addr_i[9:0]),.cfg_wdata_i(merged_data),.cfg_rdata_o(descriptor_data),
     .arm_i(command&&word[31:26]==61),
    .pair_i(command&&word[31:26]==53&&!pair_bad),
    .pair_context_a_i(pair_config_q[1:0]),.pair_context_b_i(pair_config_q[3:2]),
    .pair_base_a_i({pair_config_q[4],word[25:13]}),.pair_base_b_i({pair_config_q[5],word[12:0]}),
    .pair_arm_mask_i(pair_config_q[9:6]),
    .start_i(flow_start),
    .defer_i(word[31:26]!=62),.commit_i(flow_commit),
    .contexts_i(flow_contexts),.row_mask_i(flow_rows),.clear_error_i(clear_error),.invalidate_i(host_write_o),.invalidate_addr_i(addr_i[13:0]),
    .busy_o(busy),.error_o(io_error),.compute_safe_o(compute_safe),.prefetch_busy_o(prefetch_busy),
    .ready_o(buffer_ready),.reserved_o(reserved),.read_locks_o(read_locks),.write_locks_o(write_locks),.ended_o(ended),.buffer_regs_o(buffer_regs),.registers_i(registers),
    .load_mask_o(load_mask),.load_data_o(load_data),.load_reg_o(load_reg),
    .req_o(io_req),.we_o(io_we),.addr_o(io_addr),.be_o(io_be),.wdata_o(io_wd),
    .gnt_i(gnt[2:1]),.rvalid_i(rv[2:1]),.rdata_i(io_rd));
  mynpu_banked_sram #(.MEM_BACKEND(MEM_BACKEND),.BANK0_INIT_FILE(BANK0_INIT_FILE),
    .BANK1_INIT_FILE(BANK1_INIT_FILE)) i_memory(.clk_i(clk_i),.rst_ni(rst_ni),
    .req_i(req),.we_i(we),.addr_i(addr),.be_i(be),.wdata_i(wd),.gnt_o(gnt),.rvalid_o(rv),.rdata_o(rd));
endmodule
