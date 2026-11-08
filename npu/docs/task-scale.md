# 扩大单次任务规模

当前格式已更新为 [SD93 / Matrix 4 / VPG3](command-layout.md)：卷积核改为共享配置，任务与程序编码已调整。以下相应格式与测量属于历史版本。

后续已切换到 [SD92 显式卷积核地址](cnn-kernel-address.md)：删除 co 字段，FIFO 为 43bit，旧 SD91 固件需重生成。以下为扩大循环规模时的历史格式与测量记录。

本次在独立 IRQ 版本上扩大循环长度，没有增加 MAC、SRAM、RF 或任务队列深度。旧任务的 MMIO 编码保持兼容，原有固件无需重新生成。

| 单元 | 旧上限 | 新上限 |
|---|---|---|
| Matrix | M/N/K 各 16 | M/N 各 16，K 最大 256 |
| Vector | 1,024 个元素 | 4,096 个元素 |
| CNN | 16 个输入通道 | 256 个输入通道 |

Vector 的上限按元素数计算，适用于 INT32、INT8 SIMD 和程序模式。4,096 个 INT32 元素占满 16KB SRAM；完整非原地任务还需要输入和输出各自的空间，实际长度受容量、程序占用和别名检查限制。INT8 SIMD 每个 32 位字包含四个元素，4,096 元素占 4KB。

Matrix 保持 4×4 外积计算阵列、16 个累加器及最多 16×16 的任务输出块，只延长 K 循环。M/N 更大的矩阵继续由软件分块；K 超过 256 可以分段并使用 ACCUMULATE，最终量化需放在完整累加之后。不是任意 16×16×256 的精度与布局都能同时放入现有存储，提交时仍检查完整地址跨度、转置、leading dimension 和输出重叠。

CNN 保持 DOT9、每个任务最多八个输出位置及原有 32 位任务编码。加宽共享配置中的输入通道数和通道游标，不扩大逐通道复用的窗口/权重缓冲。任务中的 x/y 仍各 5 位、co 仍 4 位；C 兼容适配器的宽高上限仍为 28，整层输出通道参数仍最多 16。更大图像/更多输出通道需要软件重新选择基址并分块，不能直接向这些字段传入超界值。原始 MMIO 使用者必须自行验证完整张量跨度和 RF partial-buffer 的所有权。

## 能力查询与硬件代价

相对 NPU MMIO 基址 `0x40000000`，新增只读寄存器：

| 偏移 | 含义 | 当前返回值 |
|---|---|---|
| 0x074 | [31:16] K，[15:8] N，[7:0] M | 0x01001010 |
| 0x078 | Vector 最大元素数 | 4096 |
| 0x07c | CNN 最大输入通道数 | 256 |

软件接口和上限宏见 `npu/sw/npu.h`。FIFO 深度仍为 8/8/8；Matrix 每个队列条目多四位 K，Vector 每条目多两位长度，CNN 队列条目仍为 32 位。默认配置下队列有效负载共增加 48 位，另有活动配置、循环计数器及相关比较/地址跨度运算的加宽。没有新增数据缓冲，但不能据此声称面积或时序完全不变：本次尚未综合或布局布线，旧 PPA 不代表此版本。

## 验证

结果索引：`npu/reports/task-scale-validation.json`。九组 VCS 回归通过，并核对结果文件中的依赖 SHA 和运行期间源码未变化：

- `outergemm --macro`：29,946 项检查，包括 K=17/31/255/256、INT8/INT16/INT32、转置及 4×4 输出、K=256 的完整外积块。
- `cnnstream --macro`：197 个案例、1,148 项检查，包括 17/31/255/256 输入通道、第二组输出通道权重寻址及 stride/padding。
- `vectorsimd --macro`：42,594 项检查，包括 1,025/2,048/2,049/4,095/4,096 元素、INT32、INT8 SIMD、程序模式、原地操作、尾部掩码及拒绝 4,097 元素。
- `irqcontrol`、`irqwake --macro`、`queues`、`enginefaults`、`vectorprogram`：能力寄存器、独立 IRQ/WFI、队列及故障处理回归。
- `latency --macro`：原有默认 MNIST 固件 10 张图均通过，仍为 29,298 周期/图。这说明兼容性，不代表大任务已由现有 MNIST 调度利用，也不代表新增上限能直接提高并行吞吐。

复跑示例（tag 必须使用未存在的目录名）：

```bash
python3.12 npu/scripts/run_vcs.py --suite outergemm --tag taskscale_check --macro
python3.12 npu/scripts/run_vcs.py --suite cnnstream --tag taskscale_check --macro
python3.12 npu/scripts/run_vcs.py --suite vectorsimd --tag taskscale_check --macro
```
