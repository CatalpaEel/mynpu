# Descriptor 驱动 INT8 CNN NPU

此目录保留 NPU 核心、模型导出器、数据镜像和独立 testbench。完整 CPU/AXI/JTAG SoC 已整合在仓库根目录的 `rtl/mynpu_soc_top.sv`，使用方法见 [主 README](../README.md)。

核心支持输出通道并行 `LANES`、INT32 累加/bias、Q31 multiplier/shift、3×3 卷积、FC/GEMV、CHW 激活、stride 1/2、固定 padding=1 和 ReLU。模型结构由层 descriptor 决定。`cnn_npu_top` 是功能数组基线，`cnn_npu_sp_top` 是原单口 1-lane 核心，`cnn_npu_sp_lanes` 是 ASIC/FPGA 共用的单口向量核心；4-lane 配合 packed4 权重在同拍更新四个独立 MAC，见 [单口向量架构](../docs/npu-single-port-vector.md)。

## MMIO

CPU 基地址为 `0x70000000`，访问为 32-bit 小端字。

| 偏移 | 寄存器 | 含义 |
|---|---|---|
| `0x00` | CONTROL | bit0 START、bit1 IRQ enable、bit2 清 DONE/ERROR |
| `0x04` | STATUS | bit0 BUSY、bit1 DONE、bit2 ERROR |
| `0x08` | INPUT_BASE | 保留的输入地址配置寄存器，计算使用 descriptor 地址 |
| `0x0c` | OUTPUT_BASE | 保留的输出地址配置寄存器，计算使用 descriptor 地址 |
| `0x10` | DESC_BASE | descriptor 本地字节偏移 |
| `0x14` | LAYER_CFG | 低 8 bit 为层数，0 使用 MAX_LAYERS |
| `0x18` | CYCLE | 当前推理周期 |
| `0x1c` | ERROR | 读 error 标志，写清 error |
| `0x4000` 起 | 本地存储窗口 | packed 32-bit word，支持 byte enable |

IRQ 是 `DONE && IRQ_ENABLE` 的电平信号，清 DONE 后撤销。BUSY 时、`SHARED_SRAM=1` 时，CPU 对数组的写入会被忽略，读仍可发生。它不是物理单口 SRAM 仲裁，也不把 CPU 主 SRAM 与 NPU SRAM 合并。

## Descriptor

每层 36B，即 9 个小端 word。地址均是 NPU 本地 SRAM 的字节偏移。

```text
word 0: input_base
word 1: output_base
word 2: weight_base
word 3: bias_base
word 4: multiplier_base
word 5: shift_base
word 6: [7:0] H, [15:8] W, [23:16] Cin, [31:24] Cout
word 7: [7:0] outH, [15:8] outW, [23:16] stride, [31:24] flags
word 8: [7:0] input_zp, [15:8] output_zp, [23:16] qmax, [31:24] reserved
```

`flags[0]` 是 FC，`flags[1]` 是 ReLU。Conv 权重 `[Cout][Cin][3][3]`，FC 权重 `[Cout][Cin]`，激活 CHW。本模型 FC 使用 H=W=1、Cin=144。bias/multiplier 每输出通道 4B，shift 每通道 1B。`qmax=0` 时使用 DEFAULT_QMAX；当前导出器设置 qmax=127。

## 运算与量化

每次 MAC 将一个 activation 减 input zero-point，广播给当前输出通道块，每个 lane 使用对应 signed INT8 权重。累加器初始化为预先生成的 INT32 bias。每个输出使用自己的 multiplier/shift，再加 output zero-point、应用 ReLU 和饱和。

exporter 使用 `M=round(s_input*s_weight[c]/s_output*2^31)`、shift=31，要求真实 multiplier 在 [0,1)；芯片不计算浮点 scale。RTL 舍入为 `(acc*M + 2^30) >>> 31`，半整数向正无穷，与 FBGEMM 并非完全 bit-exact。当前验证逐层对整数参考精确相等，对 PyTorch 的绝对差 ≤1；这项容差只针对已验证向量。

`quint8` 的理论范围是 0..255。reduced-range observer 不等于硬件类型只允许 0..127；当前导出布局主动选用 qmax=127。详细限制见根目录 README，不能据此直接假定所有数据都可安全解释为 signed INT8。

## 独立测试

在仓库根目录执行，需 Icarus Verilog。先创建 `build` 目录：

```sh
mkdir -p build
iverilog -g2012 -s tb_cnn_npu -I cnn_npu_int8 -o build/npu.vvp cnn_npu_int8/rtl/cnn_npu_top.sv cnn_npu_int8/tb/tb_cnn_npu.sv
vvp build/npu.vvp
```

完整 SoC 验证使用根目录 `tools/run_sim.py` 和 `sim/tb_mynpu_soc.sv`，同时检查真实 CPU 软件、JTAG/SBA 和 IRQ。
