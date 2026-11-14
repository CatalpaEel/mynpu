`timescale 1ns / 1ps
// Real MMIO descriptors and real compute units; no peeking into compute values.
module tb_quant_layers;
  logic clk = 0, rst_n = 0;
  always #10 clk = ~clk;
  logic tck = 0, tms = 1, tdi = 0;
  wire tdo;
  `include "db_jtag_tasks.svh"
  `include "db_sba_access.svh"
  npu_soc dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .cpu_run_i         (1'b1),
    .tck_i             (tck),
    .tms_i             (tms),
    .td_i              (tdi),
    .td_o              (tdo),
    .cpu_debug_halted_o(),
    .irq_o             (),
    .cpu_test_done_o   (),
    .cpu_test_pass_o   ()
  );
  int checks = 0;
  localparam logic [31:0] INPUT_A=32'h80001400, OUTPUT_D=32'h80001700,
    WEIGHTS=32'h80002000, MATRIX_B=32'h80002020, CHANNEL=32'h80006000;
  task automatic bus(input bit we, input logic [31:0] a, d, output logic [31:0] result);
    sba_access(we, a, d, 4'hf, 0, result);
  endtask
  task automatic wr(input logic [31:0] a, d);
    logic [31:0] ignored;
    bus(1, a, d, ignored);
  endtask
  task automatic rd(input logic [31:0] a, output logic [31:0] d);
    bus(0, a, 0, d);
  endtask
  // id: 0 CNN, 1 Matrix, 2 Vector. Consumer multiplies by 3; producer by 2.
  task automatic configure(input int id, input logic [31:0] src, dst, input int multiplier);
    case (id)
      0: begin
        wr(WEIGHTS, 0);
        wr(WEIGHTS + 4, 32'(multiplier));
        wr(WEIGHTS + 8, 0);
        wr('h40000608, src);
        wr('h4000060c, WEIGHTS);
        wr('h40000610, dst);
        wr('h40000614, 1);
        wr('h40000618, 'h800040c0);
        wr('h4000061c, 1);
        wr('h40000620, 1);
        wr('h40000624, 1);
        wr('h4000062c, 0);
        wr('h40000630, 0);
        wr('h40000628, (0 << 0) | (2 << 4) | (1 << 7) | (1 << 8));
      end
      1: begin
        wr(MATRIX_B, 32'(multiplier));
        wr('h40000108, src);
        wr('h4000010c, MATRIX_B);
        wr('h40000110, dst);
        wr('h40000114, 1);
        wr('h40000118, 1);
        wr('h4000011c, 1);
        matrix_config(0);
      end
      2: begin
        wr('h40000208, src);
        wr('h40000218, 0);
        wr('h4000020c, dst);
        wr('h40000210, 1);
        wr('h40000214, 'h98);
        wr('h40000230, 32'(multiplier));
      end
    endcase
  endtask
  task automatic start(input int id);
    wr('h40000000 + (id == 0 ? 'h600 : id == 1 ? 'h100 : 'h200), 1);
  endtask
  task automatic wait_done(input int id);
    logic [31:0] status;
    for (int k = 0; k < 1000; k++) begin
      rd('h40000004 + (id == 0 ? 'h600 : id == 1 ? 'h100 : 'h200), status);
      if (status[2]) $fatal(1, "engine fault id=%0d", id);
      if (status[1] && !status[0]) return;
    end
    $fatal(1, "route deadlock id=%0d", id);
  endtask
  `include "test_meta.svh"
  logic [7:0] image[16384], gold[784];
  // Translate the regression oracle's old layout tuple into explicit MMIO fields.
  task automatic matrix_config(input logic [31:0] f);
    wr('h4000013c, {31'b0, f[4]});
    wr('h40000140, f[3] ? (f[4] ? 2 : 1) : 4);
    wr('h40000130, f <= 31 ? (f & 7) : f);
  endtask
  initial begin
    logic [31:0] got, word_data;
    for (int sample = 0; sample < 10; sample ++) begin
      rst_n = 0;
      repeat (5) @(negedge clk);
      rst_n = 1;
      repeat (8) @(negedge clk);
      $readmemh($sformatf("sram%0d.hex", sample), image);
      for (int w = 0; w < 4096; w++) begin
        word_data = 0;
        for (int b = 0; b < 4; b++) word_data[8*b+:8] = image[4*w+b];
        wr('h80000000 + 4 * w, word_data);
      end
      wr('h80001f0c, 1);
      wr('h80001f08, 0);
      wr('h40000008, 1);
      for (int layer = 0; layer < 6; layer++) begin
        for (int poll = 0; poll < 2000; poll++) begin
          repeat (20) @(negedge clk);
          rd('h80001f04, got);
          if (got == 32'(layer + 1)) break;
          if (poll == 1999) $fatal(1, "layer timeout sample=%0d layer=%0d", sample, layer);
        end
        $readmemh($sformatf("gold%0d_%0d.hex", sample, layer), gold, 0, layer_len[layer] - 1);
        for (int j = 0; j < layer_len[layer]; j++) begin
          if (j == 0 || ((layer_base[layer] + j) & 3) == 0)
            rd(32'((layer_base[layer] + j) & ~3), word_data);
          if (word_data[8*((layer_base[layer]+j)&3)+:8] !== gold[j])
            $fatal(
                1,
                "layer mismatch sample=%0d layer=%0d element=%0d got=%h expected=%h",
                sample,
                layer,
                j,
                word_data,
                gold[j]
            );
          checks++;
        end
        wr('h80001f08, 32'(layer + 1));
      end
      for (int poll = 0; poll < 1000; poll++) begin
        rd('h40000004, got);
        if (got == 'h600d0001) break;
        if (got == 'hbad00001 || poll == 999) $fatal(1, "CPU failed after layer checks %h", got);
      end
    end
    $display("QUANT LAYERS PASS samples=10 layers=60 bytes=%0d", checks);
    $finish;
  end
endmodule
