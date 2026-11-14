// Simulation-only convenience tasks. Every memory access below traverses the
// external TAP pins, DTM CDC, DM SBA and XBAR; no hierarchical bus injection.
bit sba_link_ready = 0;
always @(negedge rst_n) sba_link_ready = 0;
task automatic sba_link_init;
  bit discarded;
  if (!sba_link_ready) begin
    repeat (8) tick(1, 0, discarded);
    tick(0, 0, discarded);
    select_ir('h11);
    dmi_write('h10, 1);
    sba_link_ready = 1;
  end
endtask

task automatic sba_one(input bit writing, input logic [31:0] address, value,
                       input int access_size, output logic [31:0] result,
                       output bit failed);
  logic [31:0] status, control;
  control = (32'(access_size) << 17) | (writing ? 0 : 32'h00100000);
  // W1C the sticky SBA error fields before starting a new independent access.
  dmi_write('h38, control | 32'h00407000);
  dmi_write('h39, address);
  if (writing) dmi_write('h3c, value);
  for (int poll = 0; poll < 64; poll++) begin
    dmi_read('h38, status);
    if (!status[21]) begin
      failed = |status[14:12] || status[22];
      result = 0;
      if (!writing && !failed) dmi_read('h3c, result);
      return;
    end
  end
  $fatal(1, "SBA busy timeout addr=%h SBCS=%h", address, status);
endtask

task automatic sba_access(input bit writing, input logic [31:0] address, value,
                          input logic [3:0] mask, input bit expected_error,
                          output logic [31:0] result);
  bit failed, any_failed;
  logic [31:0] part;
  sba_link_init();
  result = 0;
  any_failed = 0;
  if (mask == 15) begin
    sba_one(writing, address, value, 2, result, any_failed);
  end else begin
    // SBA encodes a size, not arbitrary byte enables. Reproduce sparse SRAM/RF
    // stores as independent byte transactions; this is not an atomic bus write.
    for (int byte_lane = 0; byte_lane < 4; byte_lane++) if (mask[byte_lane]) begin
      sba_one(writing, address + 32'(byte_lane), value >> (8*byte_lane), 0, part, failed);
      result |= (part & 255) << (8*byte_lane);
      any_failed |= failed;
      if (failed) break;
    end
  end
  if (any_failed != expected_error)
    $fatal(1, "SBA error addr=%h got=%b expected=%b", address, any_failed, expected_error);
endtask
