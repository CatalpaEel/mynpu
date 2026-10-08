`timescale 1ns/1ps

//==================================================================
// Lab 1 · 验收 testbench（助教提供，禁止修改）
//==================================================================
//  这个 tb 扮演"外面那层壳"的角色：直接把矩阵 A/B 压到 simple_npu_core
//  的 act/wgt 端口上，拉一拍 start，等 done，然后从 out 端口取结果对答案。
//
//  3 组测试，逐级加难：
//    TEST1 · 单次 GEMM               —— 基本功能 + 列优先打包
//    TEST2 · 连续 2 次 GEMM          —— 考 DONE->RUN 重启路径
//    TEST3 · 连续 3 次 GEMM（含边界）—— 考累加器清零 + 10 bit 最大值 900
//
//  每次 GEMM 除了对答案，还查 3 条时序规格：
//    (a) start 之后 done 必须先拉低（上一轮的 done 不能一直挂着）
//    (b) done 置 1 后必须保持住（sticky），不能是 1 拍脉冲
//    (c) done 之后 act/wgt 被改掉，out 不许变（结果必须驻留在 PE 里）
//
//  跑法（在 lab1 根目录下）：
//    iverilog -g2012 -s tb_npu_check -o check.vvp \
//        rtl/simple_npu_pe.sv rtl/simple_npu_core.sv tb/tb_npu_check.sv
//    vvp check.vvp
//
//  通过标志：终端出现  [CHECK] ALL PASS
//==================================================================

module tb_npu_check;

  //---------------- DUT 接口信号 ----------------
  logic             clk;
  logic             rst_ni;
  logic             start;
  logic             done;
  logic [15:0][3:0] act;
  logic [15:0][3:0] wgt;
  logic [15:0][9:0] out;

  simple_npu_core dut (
      .clk   (clk),
      .rst_ni(rst_ni),
      .start (start),
      .done  (done),
      .act   (act),
      .wgt   (wgt),
      .out   (out)
  );

  //---------------- 时钟：10 ns 周期 ----------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // cycle 计数器，用于在报告里填"这组测试花了多少拍"
  integer cycle_cnt;
  always @(posedge clk) cycle_cnt = cycle_cnt + 1;

  //---------------- 全局数据 ----------------
  reg  [3:0] A     [0:3][0:3];
  reg  [3:0] B     [0:3][0:3];
  integer    C_ref [0:3][0:3];
  integer    C_hw  [0:3][0:3];

  integer i, j, k;
  integer gemm_errors;     // 单次 GEMM 的错误数
  integer test_errors;     // 当前 TEST 组的错误数
  integer total_errors;    // 全局错误数
  integer t_start;         // 当前 TEST 组的起始 cycle

  integer poll_cnt;
  reg     seen_done_low;   // start 之后有没有观察到 done == 0

  // done 置 1 后再等这么多拍，检验它是不是 sticky
  localparam integer STICKY_HOLD_CYCLES = 5;
  // 轮询 done 的上限，超过就判 TIMEOUT
  localparam integer POLL_LIMIT = 200;

  //==================================================================
  // 用数据集编号填 A / B
  //==================================================================
  task automatic set_data(input integer sel);
    begin
      for (i = 0; i < 4; i = i + 1) begin
        for (j = 0; j < 4; j = j + 1) begin
          case (sel)
            0: begin   // dense 混合矩阵
              A[i][j] = (i * 3 + j * 5) & 4'hF;
              B[i][j] = (i * 7 + j * 2) & 4'hF;
            end
            1: begin   // 单位阵 x pattern  ->  C = B
              A[i][j] = (i == j) ? 4'd1 : 4'd0;
              B[i][j] = (i * 4 + j + 1) & 4'hF;
            end
            2: begin   // 另一组 dense
              A[i][j] = (i + 2 * j) & 4'hF;
              B[i][j] = (3 * i + j + 5) & 4'hF;
            end
            3: begin   // 全 15 边界：C[i][j] = 4*15*15 = 900
              A[i][j] = 4'd15;
              B[i][j] = 4'd15;
            end
            default: begin   // 单位阵 x 单位阵  ->  C = I
              A[i][j] = (i == j) ? 4'd1 : 4'd0;
              B[i][j] = (i == j) ? 4'd1 : 4'd0;
            end
          endcase
        end
      end
    end
  endtask

  //==================================================================
  // 跑一次完整 GEMM：装载 -> start -> 等 done -> 查时序 -> 读 out -> 对答案
  //   结果累加到 gemm_errors
  //==================================================================
  task automatic run_gemm(input integer test_id, input integer gemm_id);
    begin
      gemm_errors = 0;

      // ---- 软件参考模型 ----
      for (i = 0; i < 4; i = i + 1)
        for (j = 0; j < 4; j = j + 1) begin
          C_ref[i][j] = 0;
          for (k = 0; k < 4; k = k + 1)
            C_ref[i][j] = C_ref[i][j] + A[i][k] * B[k][j];
        end

      // ---- 装载：列优先 act[j*4+i] = A[i][j]，wgt 同理 ----
      @(posedge clk);
      for (j = 0; j < 4; j = j + 1)
        for (i = 0; i < 4; i = i + 1) begin
          act[j * 4 + i] <= A[i][j];
          wgt[j * 4 + i] <= B[i][j];
        end

      // ---- start：单拍脉冲 ----
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);      // DUT 在这个沿采样到 start
      start <= 1'b0;

      // ---- 等 done ----
      //   要求先看到 done == 0（新一轮开始了、上一轮的 done 已清掉），
      //   再看到 done == 1。上一轮的 done 一直挂着不掉，会被这里抓出来：
      //   否则 tb 一看 done=1 就去读 out，读到的是上一轮的旧结果。
      poll_cnt      = 0;
      seen_done_low = 1'b0;
      while (!(seen_done_low && done === 1'b1) && poll_cnt < POLL_LIMIT) begin
        @(negedge clk);    // 在时钟下降沿采样，避开竞争
        if (done === 1'b0) seen_done_low = 1'b1;
        poll_cnt = poll_cnt + 1;
      end
      if (done !== 1'b1 || !seen_done_low) begin
        if (!seen_done_low)
          $display("[CHECK] TEST%0d GEMM%0d FAIL: done 在 start 之后从来没有拉低过（轮询 %0d 拍）",
                   test_id, gemm_id, poll_cnt);
        else
          $display("[CHECK] TEST%0d GEMM%0d FAIL: TIMEOUT waiting for done=1 (polled %0d times)",
                   test_id, gemm_id, poll_cnt);
        $display("        -> 检查 FSM：start 有没有被捕获、是不是卡在 RUN、DONE->RUN 的路径有没有写。");
        gemm_errors = gemm_errors + 1;
        disable run_gemm;   // 这次 GEMM 不用再读 out 了
      end

      // ---- done 必须 sticky：再等几拍，它还得在 ----
      repeat (STICKY_HOLD_CYCLES) @(negedge clk);
      if (done !== 1'b1) begin
        $display("[CHECK] TEST%0d GEMM%0d FAIL: done 只亮了一下就掉了（不是 sticky）",
                 test_id, gemm_id);
        $display("        -> done 置 1 后必须一直保持，直到下一次 start。");
        gemm_errors = gemm_errors + 1;
      end

      // ---- 结果必须驻留在 PE 里：改掉 act/wgt，out 不许变 ----
      //   ⚠️ 这一步是**故意**的。真实场景里，壳/CPU 完全可能在读走结果之前
      //   就开始装下一组数据。如果你的 out 是从 act/wgt 组合算出来的
      //   （没有 PE 累加寄存器、或者 DONE 期间 PE 还在继续累加），
      //   这里就会读到错的值。不改 act/wgt 的 tb 是抓不到这个 bug 的——别把它去掉。
      @(posedge clk);
      act <= ~act;
      wgt <= ~wgt;
      repeat (2) @(negedge clk);

      // ---- 读 out 并逐元素对比：列优先 out[j*4+i] = C[i][j] ----
      for (j = 0; j < 4; j = j + 1)
        for (i = 0; i < 4; i = i + 1) begin
          C_hw[i][j] = out[j * 4 + i];
          if (C_hw[i][j] !== C_ref[i][j]) begin
            if (gemm_errors < 4)   // 最多打 4 条，免得刷屏
              $display("[CHECK] TEST%0d GEMM%0d MISMATCH: FAIL_I=%0d FAIL_J=%0d HW_VAL=%0d REF_VAL=%0d",
                       test_id, gemm_id, i, j, C_hw[i][j], C_ref[i][j]);
            gemm_errors = gemm_errors + 1;
          end
        end
    end
  endtask

  //==================================================================
  // 主流程
  //==================================================================
  initial begin
    $dumpfile("npu_check.vcd");
    $dumpvars(0, tb_npu_check);

    cycle_cnt    = 0;
    total_errors = 0;
    start = 1'b0;
    act   = '0;
    wgt   = '0;

    // 复位：拉低 4 拍再释放
    rst_ni = 1'b0;
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk);
    $display("[CHECK] reset released @ cycle %0d", cycle_cnt);

    //----------------------------------------------------------------
    // TEST1 · 单次 GEMM（dense 混合矩阵）
    //----------------------------------------------------------------
    t_start = cycle_cnt;  test_errors = 0;
    set_data(0);  run_gemm(1, 1);  test_errors = test_errors + gemm_errors;
    report_test(1, t_start, test_errors);

    //----------------------------------------------------------------
    // TEST2 · 连续 2 次 GEMM，考 DONE->RUN 重启
    //   GEMM1: 单位阵 x pattern -> C = B
    //   GEMM2: 换一组 dense 数据，不再复位
    //----------------------------------------------------------------
    t_start = cycle_cnt;  test_errors = 0;
    set_data(1);  run_gemm(2, 1);  test_errors = test_errors + gemm_errors;
    set_data(2);  run_gemm(2, 2);  test_errors = test_errors + gemm_errors;
    report_test(2, t_start, test_errors);

    //----------------------------------------------------------------
    // TEST3 · 连续 3 次 GEMM，考累加器清零 + 最大值边界
    //   GEMM1: 全 15 x 全 15 -> 每个 C 都是 900（10 bit 上限附近）
    //   GEMM2: 同样的数据再跑一次 -> 结果必须还是 900
    //          （如果 acc 没清零，这里会读到 1800 截断后的值，直接抓出来）
    //   GEMM3: 单位阵 x 单位阵 -> C = I
    //----------------------------------------------------------------
    t_start = cycle_cnt;  test_errors = 0;
    set_data(3);  run_gemm(3, 1);  test_errors = test_errors + gemm_errors;
    set_data(3);  run_gemm(3, 2);  test_errors = test_errors + gemm_errors;
    set_data(4);  run_gemm(3, 3);  test_errors = test_errors + gemm_errors;
    report_test(3, t_start, test_errors);

    //----------------------------------------------------------------
    $display("--------------------------------------------------");
    if (total_errors == 0)
      $display("[CHECK] ALL PASS  (total %0d cycles)", cycle_cnt);
    else
      $display("[CHECK] FAIL: %0d error(s)", total_errors);
    $display("--------------------------------------------------");

    $finish;
  end

  // 打印一组测试的结果，并累加到全局错误数
  task automatic report_test(input integer test_id, input integer start_cycle,
                             input integer errs);
    begin
      if (errs == 0)
        $display("[CHECK] TEST%0d PASS  (%0d cycles)", test_id, cycle_cnt - start_cycle);
      else
        $display("[CHECK] TEST%0d FAIL  (%0d error(s))", test_id, errs);
      total_errors = total_errors + errs;
    end
  endtask

  //---------------- 兜底超时：DUT 彻底挂死时也能退出 ----------------
  initial begin
    #500000;
    $display("[CHECK] GLOBAL TIMEOUT — 仿真跑了 500 us 还没结束，DUT 可能挂死了。");
    $display("[CHECK] FAIL");
    $finish;
  end

endmodule
