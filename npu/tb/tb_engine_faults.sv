`timescale 1ns / 1ps
// Exercise the public request/response interface, including write acknowledgements.
// A fault must stop one job, pulse once, and leave the engine reusable.
module tb_engine_faults;
  logic clk_i = 0, rst_ni = 0;
  always #10 clk_i = ~clk_i;
  logic [1:0] start = 0, gnt = 0, rvalid = 0, error = 0;
  wire [1:0] busy, done, fault, req, we;
  wire [31:0] addr[2], wdata[2];
  logic [31:0] rdata[2] = '{0, 0};
  int checks = 0, failed_jobs = 0, successful_jobs = 0;
  matrix_task_fixture matrix (
    .clk_i,
    .rst_ni,
    .start_i (start[0]),
    .a_i     (32'h80000000),
    .b_i     (32'h80000100),
    .d_i     (32'h80000200),
    .m_i     (5'd1),
    .n_i     (5'd1),
    .k_i     (5'd2),
    .flags_i (5'd4),
    .busy_o  (busy[0]),
    .done_o  (done[0]),
    .fault_o (fault[0]),
    .req_o   (req[0]),
    .we_o    (we[0]),
    .addr_o  (addr[0]),
    .wdata_o (wdata[0]),
    .gnt_i   (gnt[0]),
    .rvalid_i(rvalid[0]),
    .error_i (error[0]),
    .rdata_i (rdata[0])
  );
  vector_task_fixture vector (
    .clk_i,
    .rst_ni,
    .start_i (start[1]),
    .a_i     (32'h80000000),
    .b_i     (32'h80000100),
    .d_i     (32'h80000200),
    .scalar_i(32'd0),
    .len_i   (11'd2),
    .op_i    (8'd1),
    .busy_o  (busy[1]),
    .done_o  (done[1]),
    .fault_o (fault[1]),
    .req_o   (req[1]),
    .we_o    (we[1]),
    .addr_o  (addr[1]),
    .wdata_o (wdata[1]),
    .gnt_i   (gnt[1]),
    .rvalid_i(rvalid[1]),
    .error_i (error[1]),
    .rdata_i (rdata[1])
  );

  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1, "%s", message);
    checks++;
  endtask

  task automatic launch_job(input int unit_id);
    @(negedge clk_i);
    start[unit_id] = 1;
    @(negedge clk_i);
    start[unit_id] = 0;
    check(busy[unit_id] && !done[unit_id] && !fault[unit_id], "Start was not accepted");
    for (int delay = 0; delay < 20 && !req[unit_id]; delay++) @(negedge clk_i);
    check(req[unit_id], "Initial operand request timeout");
    // error without ownership of a reply must not abort an ungranted request.
    error[unit_id] = 1;
    rvalid[unit_id] = 1;
    @(negedge clk_i);
    check(busy[unit_id] && req[unit_id] && !fault[unit_id], "Stray reply aborted request");
    error[unit_id] = 0;
    rvalid[unit_id] = 0;
  endtask

  task automatic transfer(input int unit_id, beat, input bit inject_error);
    bit write_expected;
    logic [31:0] expected, data;
    int waited;
    waited = 0;
    while (!req[unit_id] && waited < 20) begin
      @(negedge clk_i);
      waited++;
    end
    check(req[unit_id], "No request");
    write_expected = unit_id == 0 ? beat == 6 : beat == 3 || beat == 6;
    check(we[unit_id] == write_expected, "Unexpected transaction direction");
    if (write_expected) begin
      expected = unit_id == 0 ? 30 : beat == 3 ? 6 : 8;
      check(wdata[unit_id] == expected, "Arithmetic result mismatch");
    end
    if (unit_id == 0)
      case (beat)
        1: data = 2;
        2: data = 4;
        3: data = 3;
        4: data = 5;
        5: data = 7;
        default: data = 0;
      endcase
    else
      case (beat)
        1: data = 2;
        2: data = 4;
        4: data = 3;
        5: data = 5;
        default: data = 0;
      endcase
    gnt[unit_id] = 1;
    @(negedge clk_i);
    gnt[unit_id] = 0;
    // Both units support delayed replies. error is meaningful only with rvalid.
    error[unit_id] = 1;
    @(negedge clk_i);
    check(busy[unit_id] && !fault[unit_id], "Error without rvalid aborted WAIT");
    error[unit_id] = inject_error;
    rvalid[unit_id] = 1;
    rdata[unit_id] = data;
    @(negedge clk_i);
    rvalid[unit_id] = 0;
    error[unit_id] = 0;
    // A batched reader drains already granted lanes before reporting fault.
    if (inject_error) begin
      for (int delay = 0; delay < 6 && !fault[unit_id]; delay++) @(negedge clk_i);
      check(fault[unit_id] && !done[unit_id] && !busy[unit_id], "Bad fault result");
    end else if (beat == 6)
      check(done[unit_id] && !fault[unit_id] && !busy[unit_id], "Bad completion");
    else check(busy[unit_id] && !done[unit_id] && !fault[unit_id], "Early completion/fault");
  endtask

  initial begin
    repeat (4) @(negedge clk_i);
    rst_ni = 1;
    for (int unit_id = 0; unit_id < 2; unit_id++) begin
      // Fault every response position, then retry successfully without reset.
      // Faulting the final write acknowledgement must report fault, not done;
      // the write itself was already accepted and is not rolled back.
      for (int fail_at = 1; fail_at <= 6; fail_at++) begin
        launch_job(unit_id);
        for (int beat = 1; beat <= fail_at; beat++) transfer(unit_id, beat, beat == fail_at);
        failed_jobs++;
        @(negedge clk_i);
        check(!busy[unit_id] && !req[unit_id] && !fault[unit_id] && !done[unit_id],
              "Fault did not settle");
        launch_job(unit_id);
        for (int beat = 1; beat <= 6; beat++) transfer(unit_id, beat, 0);
        successful_jobs++;
        @(negedge clk_i);
        check(!busy[unit_id] && !req[unit_id] && !done[unit_id], "Done was not a pulse");
      end
      // Reset may discard an outstanding read without waiting for its reply.
      launch_job(unit_id);
      gnt[unit_id] = 1;
      @(negedge clk_i);
      gnt[unit_id] = 0;
      rst_ni = 0;
      @(negedge clk_i);
      rst_ni = 1;
      check(!busy[unit_id] && !req[unit_id] && !fault[unit_id] && !done[unit_id],
            "Reset did not clear job");
    end
    $display("ENGINE FAULTS PASS failed_jobs=%0d successful_retries=%0d checks=%0d", failed_jobs,
             successful_jobs, checks);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "Engine fault timeout");
  end
endmodule
