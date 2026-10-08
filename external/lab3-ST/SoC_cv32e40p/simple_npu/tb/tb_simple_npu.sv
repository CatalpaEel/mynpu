`timescale 1ns/1ps

// Lab 3 · simple_npu 单元 testbench（MMIO 壳 + 核一起测）
//   直接驱动 memory-like 端口（不经 SoC），证明 NPU 单跑可以算对。
//   3 组测例：
//     1) A = 单位阵，B = pattern        →  C = B
//     2) A、B 任意混合 4×4 矩阵          →  逐元素手算预期
//     3) A = B = 全 15，最大累加边界    →  C[i][j] = 4×15×15 = 900
//
// 跑法（在 SoC_cv32e40p/ 根目录下，iverilog -g2012）：
//   iverilog -g2012 -o simple_npu_tb.vvp -s tb_simple_npu \
//       simple_npu/rtl/simple_npu_pe.sv \
//       simple_npu/rtl/simple_npu_core.sv \
//       simple_npu/rtl/simple_npu_top.sv \
//       simple_npu/tb/tb_simple_npu.sv
//   vvp simple_npu_tb.vvp
//   # 看到 [TB] ALL PASS 即过；可选 gtkwave simple_npu_tb.vcd 看波形
//   # 文件名以你自己的为准；把核和 PE 写在同一个文件里也可以。

module tb_simple_npu;

  logic        clka;
  logic        rst_ni;
  logic        ena;
  logic        wea;
  logic [11:0] addra;
  logic [31:0] dina;
  logic [31:0] douta;

  simple_npu_top dut (
      .clka  (clka),
      .rst_ni(rst_ni),
      .ena   (ena),
      .wea   (wea),
      .addra (addra),
      .dina  (dina),
      .douta (douta)
  );

  // ---------------- 时钟 ----------------
  initial clka = 0;
  always #5 clka = ~clka;   // 100 MHz

  // ---------------- MMIO 常量 ----------------
  localparam logic [11:0] CONTROL_ADDR = 12'd0;
  localparam logic [11:0] STATUS_ADDR  = 12'd1;
  localparam logic [11:0] ACT_BASE     = 12'd16;
  localparam logic [11:0] WGT_BASE     = 12'd1024;
  localparam logic [11:0] OUT_BASE     = 12'd2048;

  // ---------------- BFM（不传 unpacked 数组）----------------
  task automatic bus_write(input logic [11:0] addr, input logic [31:0] data);
    @(posedge clka);
    ena   <= 1'b1;
    wea   <= 1'b1;
    addra <= addr;
    dina  <= data;
    @(posedge clka);
    ena   <= 1'b0;
    wea   <= 1'b0;
  endtask

  task automatic bus_read(input logic [11:0] addr, output logic [31:0] data);
    @(posedge clka);
    ena   <= 1'b1;
    wea   <= 1'b0;
    addra <= addr;
    @(posedge clka);          // 下一拍：rdata_q 更新为目标值
    ena   <= 1'b0;
    @(negedge clka);          // 稳定半拍后采样
    data = douta;
  endtask

  // ---------------- 测试数据 ----------------
  logic [3:0] A     [0:3][0:3];
  logic [3:0] B     [0:3][0:3];
  int         C_ref [0:3][0:3];
  int         C_hw  [0:3][0:3];

  int errors;
  int total_errors;

  integer i, j, k;
  logic [31:0] status_word;
  logic [31:0] rd_word;
  int          timeout;
  int          case_num;

  initial begin
    $dumpfile("simple_npu_tb.vcd");
    $dumpvars(0, tb_simple_npu);

    total_errors = 0;
    ena    = 0;
    wea    = 0;
    addra  = 0;
    dina   = 0;
    rst_ni = 0;
    repeat (4) @(posedge clka);
    rst_ni = 1;
    repeat (2) @(posedge clka);

    // ============================================================
    // 跑 3 个测例
    // ============================================================
    for (case_num = 0; case_num < 3; case_num = case_num + 1) begin

      // ---- 准备数据（按 case_num 选数据集）----
      case (case_num)
        0: begin   // 单位阵 × pattern → C = B
          for (i = 0; i < 4; i++)
            for (j = 0; j < 4; j++) begin
              A[i][j] = (i == j) ? 4'd1 : 4'd0;
              B[i][j] = (i * 4 + j + 1) & 4'hF;
            end
        end
        1: begin   // 任意混合
          for (i = 0; i < 4; i++)
            for (j = 0; j < 4; j++) begin
              A[i][j] = (i + 2 * j) & 4'hF;
              B[i][j] = (3 * i + j + 5) & 4'hF;
            end
        end
        default: begin   // 全 15 边界
          for (i = 0; i < 4; i++)
            for (j = 0; j < 4; j++) begin
              A[i][j] = 4'd15;
              B[i][j] = 4'd15;
            end
        end
      endcase

      // ---- 软件参考 ----
      for (i = 0; i < 4; i++)
        for (j = 0; j < 4; j++) begin
          C_ref[i][j] = 0;
          for (k = 0; k < 4; k++)
            C_ref[i][j] = C_ref[i][j] + A[i][k] * B[k][j];
        end

      // ---- 装载 ACT（列优先 ACT[j*4+i] = A[i][j]）----
      for (j = 0; j < 4; j++)
        for (i = 0; i < 4; i++)
          bus_write(ACT_BASE + (j * 4 + i), {28'b0, A[i][j]});

      // ---- 装载 WGT ----
      for (j = 0; j < 4; j++)
        for (i = 0; i < 4; i++)
          bus_write(WGT_BASE + (j * 4 + i), {28'b0, B[i][j]});

      // ---- 触发 START ----
      bus_write(CONTROL_ADDR, 32'h1);

      // ---- 轮询 STATUS ----
      timeout     = 0;
      status_word = 32'h0;
      while (status_word[0] == 1'b0 && timeout <= 200) begin
        bus_read(STATUS_ADDR, status_word);
        timeout = timeout + 1;
      end
      if (status_word[0] == 1'b0) begin
        $display("[TB] CASE%0d FAIL: timeout waiting DONE", case_num);
        total_errors = total_errors + 1;
      end

      // ---- 读 OUT 并对比 ----
      errors = 0;
      for (j = 0; j < 4; j++)
        for (i = 0; i < 4; i++) begin
          bus_read(OUT_BASE + (j * 4 + i), rd_word);
          C_hw[i][j] = rd_word[9:0];
          if (C_hw[i][j] !== C_ref[i][j]) begin
            $display("[TB] CASE%0d MISMATCH C[%0d][%0d]: hw=%0d ref=%0d",
                     case_num, i, j, C_hw[i][j], C_ref[i][j]);
            errors = errors + 1;
          end
        end

      if (errors == 0)
        $display("[TB] CASE%0d PASS", case_num);
      else begin
        $display("[TB] CASE%0d FAIL (%0d mismatches)", case_num, errors);
        total_errors = total_errors + errors;
      end

      repeat (2) @(posedge clka);
    end

    if (total_errors == 0)
      $display("[TB] ALL PASS");
    else
      $display("[TB] FAIL total errors=%0d", total_errors);

    $finish;
  end

endmodule
