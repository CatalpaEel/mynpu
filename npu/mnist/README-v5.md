# Tiny MNIST v5：单图低延迟与多图片流水

使用 external 的 `pool-stride2-fp32-int8` 分支、提交 `22f3555` 中现成的 INT8 checkpoint，不重新训练或校准。保留原来的五层卷积和 144→10 FC：Conv1/3/4 stride=2，Conv4 直接只计算裁剪后 3×3；卷积融合重新量化和 ReLU。张量按 CHW，权重按 OIHW / 输出通道优先布局。原来的 8KB SRAM 仍是唯一 SRAM，指令、完整权重和完整张量都驻留其中。

新增寄存器缓存的**数据工作集为 128B**：

| 用途 | 组织 | 数据容量 |
|---|---|---:|
| 输入 patch 双缓冲 | 2×32B，最大有效 patch 为 3×9 个像素 | 64B |
| 权重双缓冲 | 2×12B，conv 存 9 个权重，FC 存最多 12 个 | 24B |
| 四个部分和 | 4×24bit | 12B |
| 输出打包 | 两个待写回字和一个组装字 | 12B |
| 两组重新量化参数 | 2×{INT32 M, INT32 B} | 16B |
| 合计 | 显式触发器实现 | **128B** |

这只是缓存数据容量，还存在标签、valid、地址、计数器和运算流水寄存器。数组使用异步复位及 `ram_style="registers"`，Vivado 资源报告应保持 **2×RAMB36、0×RAMB18、0 LUT RAM**。没有新增 SRAM 宏。2×2mm 的 ASIC 总面积是否满足，需要目标标准单元库、SRAM LEF/时序模型及实际物理实现验证，不能把 FPGA LUT/FF 数换算成 mm²，也不能按 SRAM 与寄存器的容量比例推算面积。

## 运算调度

卷积每次处理同一行最多四个输出位置，使用四个部分和累加各输入通道。同一个 3×3 权重在四个输出之间复用；最多 3×9 的输入 patch 在相邻卷积窗口之间复用。每块完成后切换双缓冲，另一块同时由 NMC 预取。下一缓冲已经 ready 时直接进入 RUN，省掉原先强制经过 WAIT_TILE 的一周期气泡；切换后的第一个 RUN 周期开始再下一块预取。缓存未 ready 时才进入 WAIT_TILE。预取可在连续 grant 下每周期发出一个读请求，响应携带独立的 bank、地址和类型标记。地址和数据选择先进入操作数寄存器，再进入 MAC。

padding 对应的零乘加直接跳过。最后一个输入通道结束时，每个输出的部分和送入独立重新量化流水，MAC 开始下一块。输出打包成 32 位字，通过两个寄存器队列写回 SRAM，尾部使用字节使能。写回优先于预取；done 在运算流水、写队列及已接受总线请求全部排空后产生。FC 使用最多 12 项的输入/权重块，保持同一数值语义。

**每层最终结果仍写回 SRAM。** 缓存只保留当前和下一块，避免整层特征图占用大量触发器。多图片使用不同 SRAM 输入槽，将下一图的 RX DMA 与当前计算、上一图的 TX DMA 重叠；层间仍由 CPU 发起下一任务。

CNN 与旧矩阵单元共享 NMC master 1 并互斥，向量及三通道 DMA 保持原接口。CNN done/error 与矩阵完成共享 IRQ16。固件启用 `mie[16]`，保持 `mstatus.MIE=0`，执行 WFI；完成或错误 IRQ 唤醒 CPU，随后读 STATUS，没有进入中断 trap，也没有持续轮询争用 SRAM。与其他矩阵软件共同使用时，应先清除旧矩阵 done，避免共享 IRQ 残留使 WFI 提前醒来。

## 数值与模型核对

权重是 per-channel INT8，激活是 affine UINT8。BN 已融合。导出器检查权重 zero-point=0，并保留 checkpoint 所有 scale / zero-point：

```text
M = round_even(input_scale × weight_scale / output_scale × 2^24)
B = round_even(float_bias / output_scale × 2^24)
acc = Σ((UINT8_input - input_zero_point) × INT8_weight)
q = round_even((acc × M + B) / 2^24) + output_zero_point
```

卷积 ReLU 将 q 下限限制到 output_zero_point；随后饱和至 UINT8。FC 只饱和。正、负数均 ties-to-even。每个输出最多 144 项，每项绝对值不超过 `255×128=32640`，累加绝对值最多 4700160，落在 signed 24bit 范围内；因此 24bit 部分和和 56bit 重新量化中间值精确保留该模型的 INT32/INT64 参考结果，节省算术面积。SRAM 预取地址和响应地址标签使用 14bit 偏移（含 8192 结束边界），外部地址与描述符边界检查仍为完整 32bit。测试另覆盖 144 项全正 / 全负极值。

Q24 与 fbgemm 的浮点重新量化不保证逐位相同。所选十张图有一处 Conv3 激活差 1 LSB，最终 logits 相同。原 PyTorch INT8 checkpoint 和 Q24 定点软件参考均评估了全部 10000 张图，准确率 **99.01%**，分类差异 **0/10000**。硬件逐层严格匹配 NumPy INT64 参考，连续流水另检查最终十个 logits 与类别。测试图片取每个标签在测试集中的第一张，未筛选正确预测样本；连续流默认重复这十张两次，不代表已仿真全部 10000 张。

## 多图片 SRAM 布局与所有权

`stream_boot.hex` / `.bin` 包含 112 条实际 RV32I/CSR/WFI 指令和六层描述符，入口仍为 `0x80000080`。程序与参数仅在开始装载一次，整个连续流期间不复位 CPU。

| SRAM 地址 | 用途 |
|---|---|
| `0x80000000–0x800003ff` | 1KB 程序与描述符，描述符起于 `0x800002b0` |
| `0x80000400–0x8000135b` | 3932B 权重与 Q24 参数 |
| `0x80001360–0x8000166f` | 输入槽 0 / 当前图的 A 激活，784B |
| `0x80001670–0x8000197f` | 共用 B 激活，784B |
| `0x80001980–0x80001c8f` | 输入槽 1 / 当前图的 A 激活，784B |
| `0x80001c90 / 0x80001ca0` | 两个 16B 输出包：10B logits、2B 零填充、4B 类别 |
| `0x80001fa0 / 0x80001fa4` | READY[0/1]，主机发布 image_id+1 |
| `0x80001fa8 / 0x80001fac` | DONE[0/1]，CPU 发布 image_id+1 |
| `0x80001fb0 / 0x80001fb4` | PRED[0/1] |
| `0x80001fb8` | 总图片数，启动前设置非零值 |
| `0x80001fc0 / 0x80001fc4` | 整个流的 kernel cycles / useful MAC，32 位累计值 |

主机先保持 CPU_CONTROL=0，通过 RX DMA 装入程序、参数和前两张已量化图，清 mailbox，设置总图片数及 READY=1/2，再释放 CPU。CPU 依次使用槽 0、1、0、1……；当前槽与共用 B 缓冲之间交替执行六层。完成后先复制 logits、写类别，再发布 DONE，随后处理另一个槽。

主机看到对应 DONE 后，用 TX DMA 取出 16B 结果包；对已经释放的同一输入槽装入下下张图，DMA 完成后才更新 READY。严禁在对应 DONE 之前覆盖输入槽，也不能在旧结果被取走前发布同槽新图片。新的 READY 必须使用新 image_id+1，避免旧标志被重复消费。CPU 使用对齐 LW/移位读取 packed logits，符合 NMC 对齐约束。

为了显示 DMA 重叠，连续测试先确认下一图开始计算再回读上一包，随后装载下下图。主机完成标志轮询之间留 32 个周期。RX/TX 仍是 valid/ready/data/keep/last 原生流接口，具体物理桥位于 FPGA/ASIC 外层。输入归一化和 checkpoint 输入量化在主机执行；`inputN.hex` 为 784 个量化字节。

## 兼容的单图片模式

`boot.hex`、`params.hex`、`inputN.hex` 和 `sramN.bin/.hex` 仍提供原来的单图程序与地址布局：A=`0x80001400`，B=`0x80001800`，mailbox=`0x80001f00`。DEBUG=1 时每层等主机 ACK，便于逐项核对；DEBUG=0 自动运行。程序现在同样使用 WFI 等 CNN 完成。历史 v3 说明和资源见 [history/v3.md](history/v3.md) 及 `reports/legacy_v3/`。

NMC 的 SRAM 请求仍在获准后的一个周期返回，MMIO 请求通过一级寄存器在两个周期返回；MMIO 执行周期暂停一次仲裁，避免响应所有者冲突。接口使用 `gnt/rvalid` 握手，主机需等待 `rvalid`。新增寄存器只是 12bit 地址、32bit 数据、写方向和 pending 状态，共 46bit。

## CNN MMIO 与计数器

基址 `0x40000600`，描述符和 CONTROL / STATUS 与 v3 兼容。CONTROL bit0=start、bit1=clear；STATUS bit0=busy、bit1=done、bit2=error。非法任务不访问 SRAM；忙时写控制/描述符返回总线错误。基址字对齐，所有张量在唯一 8KB SRAM 内，输出不与输入、权重或 Q24 参数重叠。卷积尺寸 1..28、通道 1..16、stride 1/2；FC 输入 1..144、最多 16 个输出。

| 偏移 | 字段 |
|---|---|
| `00 / 04` | CONTROL / STATUS |
| `08 / 0c / 10 / 14` | 输入、权重、Q24 参数、输出地址 |
| `18 / 1c / 20 / 24` | 输入宽、高、输入通道、输出通道 |
| `28 / 2c / 30` | stride、输出宽、输出高 |
| `34 / 38 / 3c` | 输入 zero-point、输出 zero-point、OP（0=conv，1=FC） |
| `40` | 完整任务的 busy 周期，含填充、等待和排空 |
| `44` | 有效 MAC 周期，排除 padding |
| `48` | MAC 发射次数，当前实现与有效 MAC 相同 |
| `4c` | SRAM 接受的读/写事务数 |
| `50` | WAIT_TILE 等待周期 |

统计在每次任务启动后重新开始。核内有效利用率=`ΣMAC / Σbusy cycles`。连续流的系统利用率=`ΣMAC / (CPU释放至末帧结果回读的周期)`，包括换层、调度、首帧缓存填充和末帧排空，排除程序/参数和前两图的启动前装载。当前统计仅指 **CNN 的单个 MAC**；向量和旧矩阵单元不参与该模型，不把这些单元也算作满载。

## 重现与证据

```bash
cd /home/zzh/vivado/projects/xc7a35t/npu
./scripts/simulate_mnist.sh                # 十张图逐层 + 数值/描述符边界
./scripts/simulate_mnist_latency.sh        # 单图十次独立推理，无主机轮询或逐层 ACK
./scripts/simulate_mnist_stream.sh         # 二十帧，无 CPU 复位，RX/计算/TX 重叠
./scripts/simulate.sh                      # 原矩阵/向量/三通道 DMA/NMC 回归
./scripts/build_vivado.sh                  # Vivado 2025.2、XC7A35T OOC 实现
./scripts/simulate_mnist_netlist.sh        # 综合后单图、边界和 WFI 仿真
python3 mnist/validate.py

# 从现成 checkpoint 重建导出数据与两种程序；torch 2.5.1+cpu + numpy。
.venv_mnist/bin/python mnist/export.py
.venv_mnist/bin/python mnist/firmware.py
.venv_mnist/bin/python mnist/stream_firmware.py
```

所有程序、权重和图像装载通过 RX DMA；比较通过 host/NMC 或 TX DMA，未预置内部 SRAM。连续测试中的内部信号只用于观测周期、MAC 和 DMA 重叠，不提供输入数据或控制运算。`build/mnist_simulation.log`、`build/mnist_stream.log`、`build/mnist_gate/mnist_gate.log` 保存证据。`reports/mnist_validation.json` 汇总结果并核对综合源码、仿真网表、checkpoint 和导出文件哈希。

默认连续二十帧实测：**815400 次有效 MAC，核内利用率 99.11%，系统利用率 94.87%**。下一图输入 DMA 有 3528 个 beat 与计算重叠，结果 TX 有 76 个 beat 与计算重叠；所有结果包均与参考一致。实际数值以当前 validation JSON 为准。FPGA OOC 不包含板级 pin/电压约束，也不代表 ASIC 物理面积或实板下载已经验证。


## 单图片延迟

`tb_mnist_latency` 每张图单独复位、通过 RX DMA 装入程序和参数，再搬入本张图片，关闭逐层 ACK。计时从发起 CPU release MMIO 至 CPU 写出分类和成功状态，不包含程序、参数、输入的预先装载。计算期间 host 不轮询、不读取中间结果，也不进行下一图搬运；计时后检查最终十个 logits 和预测类别。该指标包含 CPU 首次配置、五次换层和 argmax，不以多图吞吐推算单图延迟。

| 指标，50MHz | v4 基线 | v5 |
|---|---:|---:|
| 有效 MAC / 图 | 40770 | 40770 |
| CNN busy 周期 / 图 | 42656 | 41095 |
| CPU release 至完成 / 图 | 43940 | 41830 |
| 核内 MAC 利用率 | 95.58% | 99.21% |
| 完整推理 MAC 利用率 | 92.79% | 97.47% |
| 单图推理延迟 | 878.80µs | 836.60µs |

十张测试图均获得相同计时，最终 logits 和类别与定点参考完全一致；延迟降低 4.80%。除硬件去掉 ready-bank 切换气泡外，CPU 固件展开十四字段的配置循环，argmax 每个 32bit 字只读取一次并移位提取四个 logits。单图程序 93 条指令，仍放在原来 SRAM 程序区，未侵入 `0x200` 描述符表。参数、张量、缓存容量均未改变。

基线 RTL、固件源与同一测试台生成的计时日志保存在 `build/baseline_single_v4/`；旧物理报告在 `reports/legacy_v4/`。新的十图逐层 RTL、二十帧流式、单图十次独立推理及原矩阵/向量/NMC/DMA 回归日志单独保存，验证脚本核对完整证据和源码哈希。约 4mm² ASIC 的实际面积仍需目标工艺库及 SRAM 宏物理模型验证。

包含当前图片输入时，32bit RX valid/ready 连续供数的仿真中，DMA 配置与 784B 搬运为 617 周期（12.34µs），输入搬运开始至分类完成为 42447 周期（848.94µs）。此指标仍不包含程序/模型初始化；若板级桥或实际外部链路供数更慢，需要按其速率重新测量。

v5 的 Vivado 2025.2 / `xc7a35tcsg324-1` 50MHz OOC 实现通过，WNS **+0.379ns**、WHS **+0.098ns**，TNS/THS=0。资源为 **13701 LUT、7483 FF、22 DSP、2 RAMB36、0 RAMB18、0 LUT RAM**。相比 v4 只增加 2 FF，128B 数据工作集和唯一 8KB SRAM 不变。综合网表单图和数值边界测试通过；汇总见 `reports/mnist_validation.json`。
