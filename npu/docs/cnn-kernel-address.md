# CNN 显式卷积核地址：SD92

CNN 任务现在直接指定卷积核地址，不再携带输出通道编号 `co`，硬件删除 `weights_base + co × cin × 9` 的计算。软件可以提交任意顺序、不同间距或重复的卷积核地址；没有 4 bit 输出通道编号带来的 16 通道限制，实际数量由存储空间、张量布局和软件调度决定。

## 提交与队列

CPU 仍使用 32 位 MMIO 写操作：

1. 写 `0x4000060c`：当前任务的卷积核起始字节地址。
2. 写 `0x40000628`：当前任务的 32 位窗口描述字。
3. 向 `0x40000600` 写 `1`：提交任务。

第三步被接受时，硬件把两份 shadow 一起快照进 FIFO。运行中可以改写 kernel/window shadow，不影响已入队或正在执行的任务；相同卷积核可以连续提交多个窗口，不必重复写地址。共享的输入基址、输出基址、行跨度、通道跨度、输入通道数、stride 和零点仍需等队列排空后才能修改。多个软件提交者需要自行串行化这三步。

例如，在共享几何配置有效且队列有空间时，可以提交 A、B、A 三个任务：

```c
uint32_t window = npu_stream_task(y, x, count, rows, left, right, dst_words);
npu_stream_submit(kernel_a, window);
npu_stream_submit(kernel_b, window_b);
npu_stream_submit(kernel_a, window_c);
```

实际程序应检查各次返回值和队列空间，并避免输出地址相互覆盖。C 的阻塞整层适配器也删除了原先 `channels <= 16` 的检查，改由完整张量范围与别名检查约束。

## 格式与硬件

窗口 shadow 的原字段位置保持不变，但低四位必须为零：

| 位段 | 内容 |
|---|---|
| [3:0] | 保留，必须为零；旧 `co` 字段已删除 |
| [8:4] | 输出行号 y |
| [13:9] | 起始 x |
| [17:14] | 本任务输出位置数量，1～8 |
| [20:18] | 三行输入有效掩码 |
| [21] / [22] | 左 / 右 padding |
| [31:23] | 输出偏移，单位为 32 位 word |

FIFO 将 15 bit 卷积核地址偏移与窗口的有效 28 bit 拼接，条目从 32 bit 变为 **43 bit**。默认深度 8，FIFO payload 共增加 **88 bit**；不增加 MAC、数据缓存或 SRAM。完整 MMIO 地址仍为 32 bit，权重支持 SRAM、RF 或既有 xbar 流地址，SRAM/RF 地址无需字对齐。

每个卷积核包含 `cin × 9` 个 INT8 权重，通道内布局保持不变。提交时检查整个卷积核的 SRAM/RF 地址跨度；非法任务置 error 且不增加 submitted。流端点按原有 FIFO 规则消费权重。输入窗口的 y/x 和几何寻址本次没有修改，仍为 5 bit。

相关 RTL：`npu_stream_pkg.sv` 定义任务，`npu_stream_control.sv` 快照地址与窗口，`npu_stream_engine.sv` 只使用活动任务中锁存的 kernel 地址。请求路由到 SRAM/RF/流端点时也依据活动任务地址，不读取后来改写的 shadow。

## 固件与兼容性

`0x40000654` 的 ABI 标识由 SD91 的 `0x53443931` 改为 **SD92 的 `0x53443932`**。旧二进制必须重新生成，不能继续把输出通道号写入窗口低四位。

- `npu_stream_task()` 删除 co 参数；`npu_stream_submit(kernel, window)` 显式接收地址。
- `npu_stream_config.kernel` 是初始地址 shadow，不是输出通道权重数组的硬件基址。
- MNIST 固件用 CPU 寄存器维护卷积核指针，每个输出通道递增 `cin × 9`；可选 RF 权重暂存后直接使用 RF 地址。
- 每通道只写一次地址，窗口任务表不增加字数。默认生产镜像已更新；共享量化实验镜像保存在 `npu/build/kernel-v1-quant-artifacts`。

## 验证与性能

`python3.12 npu/scripts/collect_kernel_address_validation.py` 审核结果和依赖 SHA，生成 `npu/reports/kernel-address-validation.json`。13 组 VCS 回归与 628 项 C 软件检查通过：

- 深度 8/16 队列：运行中改写 shadow，非顺序卷积核地址、原通道 16 以上位置、FIFO 顺序/满队列/复位、越界卷积核拒绝、旧 co 位拒绝。
- CNN Stream：197 个案例、1,148 项检查，覆盖未对齐权重、RF/SRAM、stride、padding 和最多 256 个输入通道。
- 独立 IRQ/WFI、共享可选量化、各计算单元之间的数据转发，包括流式卷积核权重。
- 默认 Vector 和共享量化两条路径：各 10 张图，逐层 60 个张量共 17,940 字节一致，各自 JTAG 42 项检查通过。

| 推理路径 | 修改前周期/图 | SD92 周期/图 |
|---|---:|---:|
| 默认 Vector 后处理 | 29,298 | 29,297 |
| 共享 QT01 后处理 | 25,965 | 26,061 |

共享量化路径增加 96 周期，约 0.37%，主要来自软件显式维护/写入卷积核地址，当前未对这部分进一步优化。本次目的为简化硬件职责与提高调度自由度，不增加计算并行度。

尚未重新综合或布局布线，不能将删除地址乘法直接等同于实测面积下降；新增 FIFO 位和提交范围检查也应计入后续 PPA。
