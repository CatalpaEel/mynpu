# 单口 SRAM 的 4-lane ASIC/FPGA NPU

2026-10-12。流片主配置为 CPU 8KB RA1SHD + NPU 8KB RA1SHD，`USE_ASIC_SRAM=1`、`NPU_LANES=4`。FPGA 使用同一 NPU 数据通路，只把 SRAM wrapper 换成 `MEM_BACKEND=1` 的同步单口 BRAM。没有增加 SRAM 宏、端口或 AXI 请求入口。

## 数据通路与调度

`cnn_npu_sp_lanes.sv` 由 descriptor 驱动，显式例化 `LANES` 个 `cnn_npu_lane_mac`。每个 lane 有 signed 9×8→17-bit 乘法和 INT32 accumulator；activation code 减 zero-point 后广播。有效 lane 的 accumulator 在同一个 `S_MAC` 时钟沿更新。尾通道的 lane 不参加 MAC、不写输出。

存储还是每周期最多一次 32-bit 请求，读延迟一拍。descriptor 分拍读取。每组输出通道的 bias、multiplier、shift 装载一次，在遍历该组的所有空间位置时复用。activation 使用一个 32-bit word cache；同一 word 中的相邻 byte 可以复用。START、每层开始、复位和输出写回都会使 cache 失效，以避免重装输入和 ping-pong 缓冲切换后读取旧数据。

一次 packed4 term 的调度如下：

```text
TERM_PREP → ACT_REQ → ACT_WAIT → WEIGHT_WAIT → MAC
               │          └ 请求第一个权重 word
               └ cache hit 时直接请求权重，跳过 ACT_WAIT

一个 activation → 广播至 4 个 lane
一个 32-bit 权重 word → 4 个 signed INT8 weight → 同拍 4 个 MAC
```

`MAC` 同时推进下一个 term；padding term 不访问 SRAM、不更新累加器。8-lane 的权重预取需要两个 word，当前在同一个单口上分拍执行。

requant 共享一个 32×32→64-bit 乘法器，按 lane 串行执行乘法、round-shift、zero-point/ReLU/clamp 三个阶段。输出保留 CHW 格式，以 byte-enable 逐 byte 写回；本版没有增加完整 line buffer 或大容量权重 cache，也没有承诺每周期都执行 4 个 MAC。

## packed4 镜像

descriptor flags bit0=FC、bit1=ReLU、bit2=PACK4。36-byte descriptor 的其他字段、总线地址与软件 START/DONE/IRQ 协议不变。PACK4 为 0 时，向量核心仍兼容原 OIHW/OC-major 镜像，但需要串行预取各 lane 的权重。

PACK4 为 1 时权重存成 `[oc//4][term][oc%4]`：

```text
term = ci                           # FC
term = ci*9 + ky*3 + kx             # 3×3 Conv
terms = Cin                         # FC
terms = Cin*9                       # Conv
weight_address = weight_base + ((oc//4)*terms + term)*4 + oc%4
```

每个 word 的 byte0..3 对应四个输出通道。尾 group 填充到四个 byte；range 校验按填充后的容量计算，weight base 必须 word aligned。bias/multiplier/shift 仍按真实输出通道数保存。activation 和 output 的区域、布局不变。

`tools/pack_model.py` 从已经量化的 `generated/8k` 镜像生成 `cnn_npu_int8/generated/8k-p4`；只重排字节，不重新量化、不引入浮点。脚本逐层断言打包前后整数 golden 相同。参数区为 4288B（原版 3984B），A=5120、B=6656、descriptor=7168，仍满足 8KB 容量。输入/输出应使用导出器的独立 ping-pong 区域；未定义任意区域重叠下的执行语义。

`generated/8k-p4/cpu.hex` 是配套 CPU 固件，6672B；CPU 经 AXI 装载 packed 参数与 descriptor。ASIC 宏没有 hex 初始化，必须像 ASIC stress test 一样通过 SBA/启动接口装载该 CPU 镜像。原 `generated/8k`、`generated/16k` 镜像和 1-lane 基线保留。

## 配置和性能

| 单口配置 | 模型镜像 | ASIC NPU cycles | 基线加速 |
|---|---|---:|---:|
| 1 lane，原串行核心 | 8k | 288390 | 1.00× |
| 2 lanes，向量核心 | 8k-p4 | 113490 | 2.54× |
| 4 lanes，向量核心 | 8k-p4 | 65732 | 4.39× |
| 8 lanes，向量核心 | 8k-p4 | 55723 | 5.18× |

这些是固定六层模型从 START 到 DONE 的功能仿真周期，不包含 CPU/SBA 装载和结果读回。4-lane 的 FPGA BRAM 与 ASIC 宏功能模型周期相同。50MHz 假设下，4-lane 计算段是 1.315ms；这不是 ASIC 频率签核结论。

`cnn_npu_subsystem` 的单口 backend 在 `LANES=1` 时选择原 `cnn_npu_sp_top`，`LANES=2/4/8` 选择新向量核心。1-lane 基线应搭配原 `8k` 镜像；PACK4 镜像不能交给原串行核心。单口物理容量目前固定 8192B；16KB 功能数组参数不等于增加了一块实际宏。

固定模型的逐层端口计数如下；read/write 是实际 SRAM 请求，不是 CPU AXI 轮询次数：

| 层 | cycles | SRAM read | SRAM write | 有效 MAC |
|---|---:|---:|---:|---:|
| Conv1 | 9980 | 2516 | 392 | 3362 |
| Conv2 | 19543 | 4821 | 784 | 12800 |
| Conv3 | 17509 | 4833 | 392 | 12800 |
| Conv4 | 5901 | 1601 | 72 | 4096 |
| Conv5 | 10831 | 2241 | 144 | 6272 |
| FC | 1968 | 579 | 10 | 1440 |
| 合计 | 65732 | 16591 | 1794 | 40770 |

相对旧版 88770 个请求，新版仅有 18385 个，减少约 79.3%。其中权重 read=11105、activation read=5288、参数 read=144、descriptor read=54；没有减少或跳过非 padding 的 MAC。平均为 0.620 MAC/cycle，单口请求占空比约 28.0%，因此后续仍可优化地址/term 流水与控制气泡，不能据此宣称 SRAM 带宽已经跑满。

## 功能回归

VCS 在 `clab` 上执行。最终算术版本的 simulator seed=271828；200 组随机算子与 64 张 MNIST 的生成 seed=14596。ASIC 宏仿真使用 `+notimingchecks +no_notifier`，真实宏 timing check/PDK 签核按约定不执行。

- 4-lane ASIC 与 FPGA：各 100 次连续六层推理，179400 个逐层输出 byte 严格等于整数 golden，并逐 byte 检查 PyTorch 差值 ≤1。
- 两个 backend：各 200 组随机 FC/Conv、stride1/2、legacy/packed4 权重、1..11 输出通道、非对齐输入/输出、INT8 极值、INT32 累加回绕、shift0/1/31/63、ReLU、qmax127/255。每次推理检查全部 8KB SRAM，包含未写区域的保持；每 11 组 warm reset，恰好 200 次 IRQ。4-lane 共覆盖 50951 个 vector-MAC 时钟沿，其中 30260 个同时启用全部四 lane。
- 两个 backend：非法 descriptor 尾部、8 层 FC 链、卷积 stride、START/DONE/CLEAR 竞争、counter 回绕与重新启动；64 张不同 MNIST 输入经真实本地总线运行。
- 完整 ASIC SoC：三次启动、每次 CPU 五轮推理；SBA busy/error/W1C 恢复、64-word SRAM 写读、128 组 crossbar 竞争、BUSY 本地访问拒绝、三次 halt/resume、JTAG/SBA/NPU 活动中的复位。
- FPGA BRAM SoC：三次启动、每次五轮推理、运行中复位、CPU ISR 和 mailbox 检查。
- 两套完整 SoC 各通过 64 张不同 MNIST 的 CPU-in-loop 测试：CPU AXI 装载模型，Debug SBA 注入输入，CPU 发 START、处理 NPU IRQ、清 DONE、读回 10 个结果；每张严格对照独立整数 golden。ASIC 与 FPGA 的仿真时间分别为 426550520000ps、375432440000ps，日志标记为 `[SOC-STREAM] PASS backend=2/1 lanes=4 CPU-in-loop vectors=64`。
- `eeml` PyTorch 重新运行全部 10000 张 MNIST：packed 整数参考与 PyTorch 均为 99.01%，argmax 差异仍为原来的四张；重排没有改变既有 Q31/FBGEMM 舍入边界。
- ASIC 的 2/8-lane：各 200 组随机 SRAM 全区比较和五次固定六层推理；原 1-lane ASIC 也重跑了五次逐层比较。2/8-lane 此处属于 NPU 回归，完整 SoC 的主验证配置是 4-lane。

随机压力测试修复了收窄寄存器后 ReLU 的 signed/unsigned 比较问题；负整数必须与显式 signed zero-point 比较，否则非零 output zero-point 会错误得到 0。

新增 ERROR→START 边界测试还捕获了旧 ERROR 状态清理逻辑覆盖同周期 START 的 BUSY 置位：状态机继续执行但 BUSY 为 0。已同时修复原 1-lane 和新向量核心，ERROR→CLEAR+START、ERROR→START 均可恢复。修复后的 ASIC/FPGA、1/4-lane 四组边界回归（seed=777）全部通过；最终两套完整 4-lane SoC 再以 seed=777 回归，均通过三次启动和每次五轮推理。

## 复现

先生成资产、固件和向量，再在有 VCS 的 Linux 主机上运行：

```sh
python tools/pack_model.py
python tools/build_firmware.py --layout 8k-p4 --gcc /path/to/riscv64-unknown-elf-gcc
python tools/build_stream_firmware.py --layout 8k-p4 --runs 1000 --gcc /path/to/riscv64-unknown-elf-gcc --objcopy /path/to/riscv64-unknown-elf-objcopy
python tools/build_npu_stress_vectors.py --cases 200 --seed 14596
python tools/mnist_regression.py --layout 8k-p4 --random-vectors 64 --seed 14596

for suite in fixed edges random mnist soc stream; do
  python tools/run_single_port_regression.py --memory asic \
    --macro-model /private/path/RA1SHD_2048x32M8.v --lanes 4 \
    --suite "$suite" --seed 271828 || exit 1
done
# FPGA: same suites, --memory fpga and omit --macro-model.
```

日志保存在 `build/sp-<memory>-l<lanes>-<suite>-s<seed>/`。工具检查退出状态、Fatal 和 PASS，不把 VCS 的退出码 0 自动当作成功。公开仓库不携带私有 SRAM 模型。

EGo1 的独立 4-lane 工程脚本为 `fpga/ego1/build_autonomous_4lane.tcl`，目录 `vivado_autonomous_4lane`；器件仍为 `xc7a35tcsg324-1`，CPU 镜像为 `generated/8k-p4/cpu.hex`。输出 bit/ltx 使用 `_4lane` 后缀。它通过原 USB-JTAG/VIO 自测，不要求外部 RISC-V Debug 探针。板上实测结果以 `fpga/ego1/README.md` 的记录为准，VCS BRAM 仿真不能代替实际下载。

修复后的完整 bitstream 已生成，50MHz 约束下 WNS=+1.036ns、WHS=+0.028ns，setup/hold failing endpoints=0；整机使用 12385 LUT、9030 FF、17 DSP、4 RAMB36。独立 NPU 综合脚本还断言保留四个 MAC 实例。

2026-10-13 新 4-lane 已实际下载至 EGo1 XC7A35T，经板载 USB-JTAG/VIO 通过 21 次启动、105 次固定输入推理；每次 class=2、IRQ edges=4、error=0、NPU cycles=65732。CPU 每轮严格对照 10-byte 整数 golden，检查 PyTorch 差值 ≤1，并在 20 次复位保持期间检查 mailbox/IRQ 归零。外部 RISC-V Debug 下载器没有参与；64 张不同 MNIST 的 CPU-in-loop 仍是 VCS 仿真覆盖。本机完整日志为 `build/ego1-4lane-board-20261013.log`，命令和板上记录见 FPGA README。
