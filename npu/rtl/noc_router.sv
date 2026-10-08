// Five ports: local, east, west, south, north. Two independently buffered
// virtual networks: request 0, response 1. Synchronous reliable flit links.
module noc_router #(
 parameter int DEPTH=2,
 parameter int PW=DEPTH<=1 ? 1 : $clog2(DEPTH)
)(
 input logic clk_i,rst_ni,
 input logic [3:0] node_x_i,node_y_i,
 input logic [4:0] port_enable_i,
 input logic [4:0][1:0] in_valid_i,
 output logic [4:0][1:0] in_ready_o,
 input logic [4:0][1:0][31:0] in_data_i,
 input logic [4:0][1:0] in_last_i,
 output logic [4:0][1:0] out_valid_o,
 input logic [4:0][1:0] out_ready_i,
 output logic [4:0][1:0][31:0] out_data_o,
 output logic [4:0][1:0] out_last_o
);
 (* ram_style="registers" *) logic [32:0] fifo[5][2][DEPTH];
 logic [PW-1:0] rd[5][2],wr[5][2];
 logic [PW:0] count[5][2];
 logic packet[5][2];logic [2:0] route_q[5][2];
 logic locked[5][2];logic [2:0] owner[5][2],rr[5][2];
 logic [2:0] target[5][2],chosen[5][2];
 logic [4:0][1:0] pop,push;
 function automatic logic [2:0] route(input logic [31:0] h);
  if(h[23:20]>node_x_i)return 1;
  if(h[23:20]<node_x_i)return 2;
  if(h[27:24]>node_y_i)return 3;
  if(h[27:24]<node_y_i)return 4;
  return 0;
 endfunction
 always_comb begin
  pop='0;push='0;in_ready_o='0;out_valid_o='0;out_data_o='0;out_last_o='0;
  for(int p=0;p<5;p++)for(int v=0;v<2;v++)begin
   target[p][v]=packet[p][v] ? route_q[p][v] : route(fifo[p][v][rd[p][v]][31:0]);
   in_ready_o[p][v]=rst_ni && port_enable_i[p] && count[p][v]<DEPTH;
   push[p][v]=in_valid_i[p][v] && in_ready_o[p][v];
  end
  for(int o=0;o<5;o++)for(int v=0;v<2;v++)begin
   logic found;int candidate;
   found=0;chosen[o][v]=owner[o][v];
   for(int k=0;k<5;k++)begin
    candidate=(int'(rr[o][v])+k)%5;
    if(!found && (!locked[o][v] || owner[o][v]==3'(candidate)) && count[candidate][v]!=0 && target[candidate][v]==3'(o))begin
     chosen[o][v]=3'(candidate);found=1;
    end
   end
   if(found && port_enable_i[o] && rst_ni)begin
    out_valid_o[o][v]=1;out_data_o[o][v]=fifo[chosen[o][v]][v][rd[chosen[o][v]][v]][31:0];
    out_last_o[o][v]=fifo[chosen[o][v]][v][rd[chosen[o][v]][v]][32];
    pop[chosen[o][v]][v]=out_ready_i[o][v];
   end
  end
 end
 always_ff @(posedge clk_i or negedge rst_ni)begin
  if(!rst_ni)begin
   for(int p=0;p<5;p++)for(int v=0;v<2;v++)begin
    rd[p][v]<=0;wr[p][v]<=0;count[p][v]<=0;packet[p][v]<=0;route_q[p][v]<=0;
    locked[p][v]<=0;owner[p][v]<=0;rr[p][v]<=0;
    for(int b=0;b<DEPTH;b++)fifo[p][v][b]<=0;
   end
  end else begin
   for(int p=0;p<5;p++)for(int v=0;v<2;v++)begin
    if(push[p][v])begin
     fifo[p][v][wr[p][v]]<={in_last_i[p][v],in_data_i[p][v]};wr[p][v]<=wr[p][v]==PW'(DEPTH-1)?0:wr[p][v]+1'b1;
    end
    if(pop[p][v])begin
     if(!packet[p][v])route_q[p][v]<=target[p][v];
     packet[p][v]<=!fifo[p][v][rd[p][v]][32];rd[p][v]<=rd[p][v]==PW'(DEPTH-1)?0:rd[p][v]+1'b1;
    end
    case({push[p][v],pop[p][v]})
     2'b10:count[p][v]<=count[p][v]+1'b1;
     2'b01:count[p][v]<=count[p][v]-1'b1;
     default:;
    endcase
    if(out_valid_o[p][v])begin
     // Reserve on presentation, before acceptance: stable even under backpressure.
     locked[p][v]<=1;owner[p][v]<=chosen[p][v];
     if(out_ready_i[p][v] && out_last_o[p][v])begin
      locked[p][v]<=0;rr[p][v]<=chosen[p][v]==4?0:chosen[p][v]+1'b1;
     end
    end
   end
  end
 end
 initial begin
  if(DEPTH<1)$fatal(1,"Invalid NoC router parameters");
 end
endmodule
