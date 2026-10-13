`timescale 1ns/1ps

// Multi-vector RTL check for the complete quantized MNIST input range.  The
// Python regression writes deterministic random test-set samples and their
// integer golden output into the two hex files consumed here.  Every vector
// is loaded through the same local SRAM bus that the CPU uses; no memory
// backdoor is used for activations.
module tb_cnn_npu_mnist #(
  parameter integer VECTORS = 64,
  parameter integer INPUT_BYTES = 784,
  parameter integer OUTPUT_BYTES = 10,
  parameter integer LANES = 1,
  parameter integer MEM_BACKEND = 1,
  parameter INPUT_HEX = (LANES==1) ? "build/mnist-regression/mnist_input_codes_8k.hex" : "build/mnist-regression/mnist_input_codes_8k-p4.hex",
  parameter GOLDEN_HEX = (LANES==1) ? "build/mnist-regression/mnist_integer_outputs_8k.hex" : "build/mnist-regression/mnist_integer_outputs_8k-p4.hex",
  parameter MEM_HEX = (LANES==1) ? "cnn_npu_int8/generated/8k/npu_word.hex" : "cnn_npu_int8/generated/8k-p4/npu_word.hex"
);
  localparam integer LOCAL_BASE = 14'h1000;
  localparam integer INPUT_BASE = 5120;

  logic clk = 1'b0;
  logic rst_ni = 1'b0;
  logic ena = 1'b0;
  logic wea = 1'b0;
  logic [3:0] be = 4'hf;
  logic [13:0] addra = '0;
  logic [31:0] dina = '0;
  logic [31:0] douta;
  logic irq;
  logic [7:0] input_codes [0:VECTORS*INPUT_BYTES-1];
  logic [7:0] expected_codes [0:VECTORS*OUTPUT_BYTES-1];
  integer run, word, lane, poll, output_word, output_lane, got, expected;
  integer errors;
  logic [31:0] word_data, value, status;
  logic [31:0] init_words [0:2047];

  always #5 clk = ~clk;
  initial $readmemh(INPUT_HEX, input_codes);
  initial $readmemh(GOLDEN_HEX, expected_codes);
  initial if (MEM_BACKEND==2) $readmemh(MEM_HEX,init_words);

  cnn_npu_subsystem #(
    .LANES(LANES),
    .SRAM_BYTES(8192),
    .MAX_LAYERS(8),
    .MEM_BACKEND(MEM_BACKEND),
    .MEM_INIT_FILE(MEM_BACKEND==1 ? MEM_HEX : "")
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .req_i(ena), .we_i(wea), .be_i(be),
    .addr_i({16'd0,addra,2'b00}), .wdata_i(dina), .rdata_o(douta), .irq_o(irq)
  );

  task automatic bus_write(input integer address, input logic [31:0] data);
    begin
      @(negedge clk); ena = 1'b1; wea = 1'b1; addra = address; dina = data;
      @(posedge clk);
      @(negedge clk); ena = 1'b0; wea = 1'b0; addra = '0; dina = '0;
    end
  endtask

  task automatic bus_read(input integer address, output logic [31:0] data);
    begin
      @(negedge clk); ena = 1'b1; wea = 1'b0; addra = address;
      @(posedge clk);
      @(negedge clk); @(posedge clk); #1 data = douta;
      @(negedge clk); ena = 1'b0; addra = '0;
    end
  endtask

  task automatic load_input(input integer vector_index);
    integer b;
    begin
      for (word = 0; word < INPUT_BYTES/4; word = word + 1) begin
        word_data = '0;
        for (b = 0; b < 4; b = b + 1)
          word_data[b*8 +: 8] = input_codes[vector_index*INPUT_BYTES + word*4 + b];
        bus_write(LOCAL_BASE + INPUT_BASE/4 + word, word_data);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk);
    if (MEM_BACKEND==2)
      for (integer k=0;k<2048;k++) bus_write(LOCAL_BASE+k,init_words[k]);
    bus_write(4, 7168); // descriptor base in the 8 KB image
    bus_write(5, 6);    // six CNN layers
    errors = 0;

    for (run = 0; run < VECTORS; run = run + 1) begin
      load_input(run);
      bus_write(0, 1); // start
      status = '0;
      poll = 0;
      while (!status[1] && poll < 2000000) begin
        bus_read(1, status);
        poll = poll + 1;
      end
      if (!status[1])
        $fatal(1, "MNIST vector timeout vector=%0d status=%h polls=%0d", run, status, poll);

      for (lane = 0; lane < OUTPUT_BYTES; lane = lane + 1) begin
        output_word = LOCAL_BASE + (INPUT_BASE + lane)/4;
        output_lane = (INPUT_BASE + lane) % 4;
        bus_read(output_word, value);
        got = (value >> (output_lane*8)) & 8'hff;
        expected = expected_codes[run*OUTPUT_BYTES + lane];
        if (got !== expected) begin
          $display("[CNN-MNIST] vector=%0d output[%0d] hw=%0d expected=%0d", run, lane, got, expected);
          errors = errors + 1;
        end
      end
      bus_write(0, 4); // clear done before the next vector
    end

    if (errors != 0)
      $fatal(1, "MNIST random vector regression failed errors=%0d", errors);
    $display("[CNN-MNIST] PASS backend=%0d lanes=%0d vectors=%0d input_bytes=%0d", MEM_BACKEND, LANES, VECTORS, INPUT_BYTES);
    $finish;
  end
endmodule
