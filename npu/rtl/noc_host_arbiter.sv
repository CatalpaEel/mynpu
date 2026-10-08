// Two requesters sharing the existing native NMC host port. One outstanding
// request, round-robin acceptance, response always returned to its owner.
module noc_host_arbiter(
 input logic clk_i,rst_ni,
 input logic [1:0] req_i,we_i,input logic [1:0][3:0] be_i,
 input logic [1:0][31:0] addr_i,wdata_i,
 output logic [1:0] gnt_o,rvalid_o,error_o,output logic [1:0][31:0] rdata_o,
 output logic req_o,we_o,output logic [3:0] be_o,
 output logic [31:0] addr_o,wdata_o,
 input logic gnt_i,rvalid_i,error_i,input logic [31:0] rdata_i
);
 logic pending,owner,rr,selected;
 always_comb begin
  selected=req_i[rr] ? rr:!rr;
  req_o=rst_ni && !pending && req_i[selected];we_o=we_i[selected];be_o=be_i[selected];addr_o=addr_i[selected];wdata_o=wdata_i[selected];
  gnt_o='0;rvalid_o='0;error_o='0;rdata_o='0;
  if(req_o && gnt_i)gnt_o[selected]=1;
  if(pending && rvalid_i)begin rvalid_o[owner]=1;error_o[owner]=error_i;rdata_o[owner]=rdata_i;end
 end
 always_ff @(posedge clk_i or negedge rst_ni)begin
  if(!rst_ni)begin pending<=0;owner<=0;rr<=0;end
  else begin
   if(req_o && gnt_i)begin pending<=1;owner<=selected;end
   if(pending && rvalid_i)begin pending<=0;rr<=!owner;end
  end
 end
endmodule
