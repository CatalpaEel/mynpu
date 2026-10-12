# mynpu：tiny MNIST INT8 完整 SoC

本工程在独立目录中整合了 **CV32E40P CPU、3×4 AXI crossbar、原有 JTAG/Debug Module、Boot RAM、CPU SRAM 和 INT8 CNN NPU**。默认配置是 CPU 8KB + NPU 8KB，NPU 同时计算 8 个输出通道。原始 `lab3-ST` 未修改；复用源码保存在 `third_party/lab3`，新增集成顶层是 `rtl/mynpu_soc_top.sv`。

这是已通过完整 SoC 功能仿真、FPGA BRAM 后端仿真和 EGo1 Vivado bitstream 生成的 RTL 工程。默认功能 backend 适合算法基线；`USE_FPGA_BRAM=1` 会同时替换 CPU/NPU 为同步单端口 BRAM 后端，`USE_ASIC_SRAM=1` 会同时替换为 RA1SHD wrapper，并由 `cnn_npu_sp_top` 采用逐拍单端口调度。EGo1 工程已经完成综合、实现、时序和 bitstream 生成；真实板卡下载、FT232H/OpenOCD/GDB 联调以及 0.18µm 工艺综合、时序和物理签核仍需在对应硬件和 PDK 环境完成。

## 架构

```mermaid
flowchart LR
  HOST[外部 RISC-V JTAG 调试器] --> TAP[JTAG TAP / DMI]
  TAP --> DM[Debug Module]
  DM -->|停机 / 恢复| CPU[CV32E40P RV32IMC]
  CPU -->|取指请求入口 0| AXI[32-bit AXI crossbar 3×4]
  CPU -->|数据请求入口 1| AXI
  DM -->|SBA 请求入口 2| AXI
  AXI --> BOOT[Boot RAM 64B]
  AXI --> RAM[CPU SRAM 默认 8KB]
  AXI --> NPU[NPU MMIO / 计算核心]
  AXI -->|调试程序执行窗口| DM
  NPU --- LOCAL[NPU 本地存储 默认 8KB]
  NPU -->|完成中断 IRQ 16| CPU
```

NPU 是 AXI 从设备；它从本地存储读取参数、输入和层描述符，不包含 AXI DMA master。外部可通过原有 JTAG → DMI → Debug Module SBA 加载程序和访问 NPU，保留三个 AXI 请求入口即可。

## 复现完整 SoC 仿真

需要 Python 3 和支持 SystemVerilog 类型参数的 VCS。仓库包含 CPU 程序镜像和模型数据；直接运行仿真不需要 PyTorch 或 RISC-V 编译器。

```sh
git clone https://github.com/one-bite-one-pig/mynpu.git
cd mynpu
python3 tools/verify_assets.py
python3 tools/run_sim.py --backend vcs --layout 8k --lanes 8
python3 tools/run_sim.py --backend vcs --layout 16k --lanes 16
python3 tools/run_sim.py --backend vcs --layout 8k --lanes 1
# SoC stress: reset pulses, 64 SBA words, invalid-config recovery, 3 halt/resume rounds
python3 tools/run_sim.py --backend vcs --layout 8k --lanes 8 --stress
# FPGA BRAM / single-port schedule regression (Icarus)
iverilog -g2012 -s tb_cnn_npu_sp -o build/tb_cnn_npu_sp.vvp \
  sim/tb_cnn_npu_sp.sv cnn_npu_int8/rtl/cnn_npu_sp_top.sv \
  rtl/mynpu_sram_2048x32_fpga.sv
vvp build/tb_cnn_npu_sp.vvp

# 完整 MNIST 测试集的 PyTorch INT8 / RTL 整数参考，以及 64 张随机样本的 RTL 回灌
conda run -n eeml python tools/mnist_regression.py --layout 8k --random-vectors 64

# CPU-in-loop：CPU AXI 写模型、Debug SBA 注入输入、CPU IRQ 读回结果
python tools/build_stream_firmware.py --runs 1000
vcs -full64 -sverilog -assert svaext -timescale=1ns/1ps +define+SYNTHESIS \\
  -f sim/soc.f sim/tb_mynpu_soc_stream.sv -top tb_mynpu_soc_stream \\
  -pvalue+tb_mynpu_soc_stream.VECTORS=64 -o build/vcs-soc-stream/simv
build/vcs-soc-stream/simv

# AXI 随机 burst + 每响应拍随机 RREADY/BREADY（在 VCS 主机上运行）
vcs -full64 -sverilog -assert svaext -timescale=1ns/1ps \
  +incdir+third_party/lab3/soc/rtl/include +incdir+third_party/lab3/soc/rtl \
  third_party/lab3/soc/rtl/axi/axi_pkg.sv \
  third_party/lab3/soc/rtl/axi/axi_intf.sv \
  third_party/lab3/soc/rtl/axi/axi2mem.sv sim/tb_axi2mem_backpressure.sv \
  -top tb_axi2mem_backpressure -pvalue+tb_axi2mem_backpressure.TRANSACTIONS=1000 \
  -o build/vcs-axi-bp/simv
build/vcs-axi-bp/simv +ntb_random_seed=14596
```

成功标志是 `[SOC] PASS`，脚本会检查该标志，不能只依据模拟器退出码判断成功。日志在 `build/vcs-<layout>-<lanes>/`。Vivado 2023.2 XSim 对原始 AXI 源码中的 `default disable iff` 不支持，因此当前验证使用 VCS。

完整 testbench 通过真实 CPU 指令执行以下流程：JTAG SBA 读写两块 SRAM → CPU 启动 → JTAG 停机、读取/写入/恢复 x31 → CPU 加载模型并进行第一轮轮询推理 → 连续四轮重新装载输入、启动、处理中断并清除 DONE。五轮推理每层都严格对照独立 Python 整数参考，同时逐元素检查与 PyTorch FBGEMM 的差值不超过 1。CPU 和 NPU 的同步 BRAM 版本另有 `sim/tb_mynpu_soc_fpga.sv`，单端口 NPU 的独立回归是 `sim/tb_cnn_npu_sp.sv`。

## 参数与地址

| 顶层参数 | 默认值 | 含义 |
|---|---:|---|
| `CPU_SRAM_BYTES` | 8192 | CPU 程序、数据和栈容量 |
| `NPU_SRAM_BYTES` | 8192 | NPU 参数、激活和描述符容量 |
| `NPU_LANES` | 8 | 功能数组 backend 的输出通道并行数；单端口 FPGA/ASIC backend 当前按 `LANES=1` 使用 |
| `NPU_IRQ_ID` | 16 | 接入 CV32E40P 的中断编号 |
| `CPU_INIT_FILE` | 空 | CPU RAM 仿真/FPGA 初始镜像 |
| `NPU_INIT_FILE` | 空 | 可选 NPU RAM 初始镜像 |

CPU 固件当前对应 8KB CPU SRAM、中断 16；改变这两项须同步修改 `sw/linker.ld` 和 `sw/main.c` 后重新编译。`8k/16k` 选项改变 NPU SRAM 布局，CPU SRAM 保持 8KB。`boot_ready_i=1` 允许 CPU 取指；动态加载时先保持为 0，再通过 SBA 加载并使能取指。ASIC 中 `.hex` 初始化不能替代实际程序加载。

| 地址 | 用途 |
|---|---|
| `0x0000_0000 .. 0x0000_0fff` | Debug Module 的 CPU 可见窗口 |
| `0x0001_0000 .. 0x0001_003f` | Boot RAM，跳转到 CPU SRAM |
| `0x8000_0000 .. 0x8000_1fff` | 默认 CPU SRAM |
| `0x7000_0000` | NPU CONTROL：START bit0、IRQ enable bit1、清状态 bit2 |
| `0x7000_0004` | STATUS：BUSY bit0、DONE bit1、ERROR bit2 |
| `0x7000_001c` | ERROR：普通 NPU 错误为 bit0；单口 SRAM 在 BUSY 期间的违规本地访问返回 `0xdead_b001` |
| `0x7000_0010` | 本地 SRAM 中的描述符字节偏移 |
| `0x7000_0014` | 推理层数，本模型为 6 |
| `0x7000_0018` | NPU 运行周期计数 |
| `0x7000_4000` 起 | NPU SRAM 的 32-bit、小端访问窗口 |
| `0x8000_1fc0 .. 0x8000_1fff` | 自测结果 mailbox |

当前默认 VCS 回归仍使用高并行功能 backend；FPGA/ASIC 版本通过 `USE_FPGA_BRAM=1` 或 `USE_ASIC_SRAM=1` 选择 CPU 与 NPU 的同步单端口 SRAM backend，此时建议 `NPU_LANES=1`。`SHARED_SRAM=1` 规定 NPU BUSY 时主机本地写不落 SRAM、违规本地读返回确定错误标记，不代表 CPU 主存与 NPU 已共用一个物理 SRAM。

## 模型及整数运算

模型来自 [tiny_MNIST 的 pool-stride2-fp32-int8 分支](https://github.com/CatalpaEel/tiny_MNIST/tree/pool-stride2-fp32-int8)，checkpoint 存在 `model/checkpoints/model_int8.pt`。卷积的 BatchNorm 和 ReLU 已在 PyTorch 量化流程中融合。

| 层 | 输入 CHW | 输出 CHW | 核 / stride |
|---|---|---|---|
| Conv1 + ReLU | 1×28×28 | 2×14×14 | 3×3 / 2 |
| Conv2 + ReLU | 2×14×14 | 4×14×14 | 3×3 / 1 |
| Conv3 + ReLU | 4×14×14 | 8×7×7 | 3×3 / 2 |
| Conv4 + ReLU | 8×7×7 | 8×3×3 | 3×3 / 2，保留原 4×4 的左上 3×3 |
| Conv5 + ReLU | 8×3×3 | 16×3×3 | 3×3 / 1 |
| FC | 144 | 10 | 10×144 |

输入/中间值保存为 8-bit activation code，权重为 per-output-channel signed INT8；芯片不做浮点输入量化或 BatchNorm 运算。导出器预先生成 INT32 bias、每通道 Q31 multiplier 和 shift：

```text
b_int[c] = round(b_float[c] / (s_input * s_weight[c]))
acc[c]   = b_int[c] + Σ ((q_input - z_input) * q_weight[c])
M[c]     = round((s_input * s_weight[c] / s_output) * 2^31)
q_output = clamp(((acc[c] * M[c] + 2^30) >> 31) + z_output, 0, qmax)
```

ReLU 在 clamp 前将值下限设为 `z_output`。此 RTL 的半整数舍入向正无穷；它与 FBGEMM 的浮点 requant 不完全 bit-exact。当前固定向量的最终整数输出为 `[68,50,82,68,55,80,75,63,76,59]`，PyTorch 为 `[68,49,82,68,55,80,75,63,76,59]`，两者 argmax 都是 2。

当前描述符 `qmax=127`。`quint8` 本身仍允许 0..255；reduced-range observer 不能保证任意输入下所有转换后算子的输出都 ≤127。现有验证向量满足该范围，尚未做全测试集的 RTL 精度评估。更换数据分布或 qmax 后应重新做模型与 RTL 对照，不能直接把 activation 当 signed INT8 使用。

## 重新导出和编译

已实际验证的 PyTorch 版本为 2.2.2 CPU，使用 FBGEMM。更高版本应先确认旧 checkpoint 和量化 API 的兼容性。

```sh
python cnn_npu_int8/tools/export_model.py --checkpoint model/checkpoints/model_int8.pt --out-dir cnn_npu_int8/generated/8k --sram-bytes 8192 --lanes 8
python cnn_npu_int8/tools/export_model.py --checkpoint model/checkpoints/model_int8.pt --out-dir cnn_npu_int8/generated/16k --sram-bytes 16384 --lanes 16
python tools/build_firmware.py --layout 8k --gcc /path/to/riscv64-unknown-elf-gcc
python tools/build_firmware.py --layout 16k --gcc /path/to/riscv64-unknown-elf-gcc
```

编译器须支持 `-march=rv32imc_zicsr -mabi=ilp32`，匹配的 objcopy 默认从 gcc 路径推导，也可以传 `--objcopy`。固件、模型常量共约 6.3KB，另保留 1KB 栈和 64B mailbox。模型数据先在 CPU RAM 的只读区，再由 CPU 写入 NPU RAM。

详细验证数据见 [docs/verification.md](docs/verification.md)，JTAG/存储/流片边界见 [docs/integration.md](docs/integration.md)，SRAM 宏与 FPGA 替身见 [docs/sram-and-fpga.md](docs/sram-and-fpga.md)，上板指导见 [EGO1 指导](cnn_npu_int8/docs/fpga-ego1-guide.md)。

## EGo1 无 Debug Module 上板自测

`fpga/ego1/ego1_autonomous_top.sv` 是独立的 EGo1 顶层：CPU 和 NPU 都使用
FPGA BRAM，CPU 固件自动加载模型并连续完成五轮推理，外部只需要板载
USB-JTAG 配置口。`fpga/ego1/program_autonomous.tcl` 用 Vivado Hardware
Manager 下载 bitstream，并通过 VIO 读取 mailbox、IRQ 和分类结果、控制软复位；
它不使用 OpenOCD/GDB，也不需要 RISC-V JTAG 的 FT232H 或杜邦线。该路径已在
真实 `xc7a35tcsg324-1` 上完成 4 次启动、20 次推理回归。具体命令和 LED 定义见
[EGo1 FPGA README](fpga/ego1/README.md)。

当前 FPGA/ASIC 单端口存储 backend 以 `LANES=1` 为真实吞吐配置；它接受
`NPU_LANES=8` 参数但仍按单端口串行访问。`fpga/ego1/build_autonomous_8lane.tcl`
可以生成 8-lane 参数实验 bitstream，用于检查功能和参数传递；要获得真正
8 路并行，下一版需要 banked SRAM 或权重缓存。
