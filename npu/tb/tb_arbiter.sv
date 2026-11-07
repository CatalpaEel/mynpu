`timescale 1ns / 1ps
module arbiter_check #(
  parameter int N = 9,
  IW = N > 1 ? $clog2(N) : 1
) (
  output logic done = 0
);
  logic [N-1:0] req_i = 0, grant_o;
  logic [IW-1:0] first_i = 0, index_o;
  logic valid_o;
  npu_rr_select #(
    .N (N),
    .IW(IW)
  ) dut (
    .*
  );
  initial begin
    logic [N-1:0] expected;
    int expected_index, candidate, checks;
    checks = 0;
    for (int first = 0; first < N; first++)
    for (int requests = 0; requests < (1 << N); requests++) begin
      first_i = IW'(first);
      req_i = N'(requests);
      expected = 0;
      expected_index = 0;
      for (int step = 0; step < N; step++) begin
        candidate = (first + step) % N;
        if (expected == 0 && req_i[candidate]) begin
          expected[candidate] = 1;
          expected_index = candidate;
        end
      end
      #1;
      if(grant_o!==expected || valid_o!== (requests!=0) || (valid_o && index_o!==IW'(expected_index)))
        $fatal(
            1,
            "RR mismatch N=%0d first=%0d req=%h grant=%h expected=%h",
            N,
            first,
            req_i,
            grant_o,
            expected
        );
      checks++;
    end
    $display("RR EXHAUSTIVE N=%0d checks=%0d", N, checks);
    done = 1;
  end
endmodule
module tb_arbiter;
  wire [5:0] done;
  arbiter_check #(.N(1)) a (done[0]);
  arbiter_check #(.N(3)) b (done[1]);
  arbiter_check #(.N(4)) c (done[2]);
  arbiter_check #(.N(6)) d (done[3]);
  arbiter_check #(.N(7)) e (done[4]);
  arbiter_check #(.N(9)) f (done[5]);
  initial begin
    wait (&done);
    $display("ARBITER PASS exhaustive requests and legal RR pointers N=1,3,4,6,7,9");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
