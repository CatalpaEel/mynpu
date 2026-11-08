`define NPU_EXPECTED_MATRIX_JOBS 37
localparam int PROGRAM_BYTES=4864;
localparam int STREAM_TASKS=212;
localparam int PARAM_BYTES=4052;
int layer_len[6]='{392,784,392,72,144,10};
int layer_base[6]='{2147489792,2147488768,2147489792,2147500032,2147500104,2147488768};
int prediction[10]='{0,1,2,3,4,5,6,7,8,9};
int expected_macs[6]='{3362,12800,12800,4096,6272,0};
int expected_terms[6]='{1148,4480,4480,1536,2688,0};
