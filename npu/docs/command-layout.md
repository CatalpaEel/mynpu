# 当前命令格式：SD95 / Matrix 4 / VPG3

配置写入时序以[软件负责配置一致性](software-owned-config.md)为准；当前 Operator ABI 2.2，不再强制运行中禁止写配置。下文相应排空要求为此前约束。

当前CNN采用SD95：count字段为count−1，占4bit，表示1～16个位置。基础任务编码仍需结合[LY01布局与EV01事件](layout-events.md)及当前`npu/sw/npu.h`查看。
默认性能与PPA仅使用[RF 1R1W报告](rf1r1w.md)和[最终r3后端](rf1r1w-die1950-signoff.md)。下方是字段重排时的接口记录，任务队列深度及历史验证数不代表最新配置。

## CNN：输入与卷积核都共享

所有偏移相对 MMIO 基址 `0x40000000`。

| 偏移 | 配置 | 作用范围 |
|---|---|---|
| 0x608 | src 输入基址 | 共享，队列排空后才能修改 |
| 0x60c | kernel 卷积核基址 | 共享，队列排空后才能修改 |
| 0x610 | dst 原始输出基址 | 共享 |
| 0x614 | row_stride，输入行跨度，字节 | 共享 |
| 0x618 | partial，RF 内最多 16×32bit 部分和空间，按任务数量校验 | 共享 |
| 0x61c | cin，1～256 | 共享 |
| 0x620 | stride，1 或 2 | 共享 |
| 0x624 | plane_stride，输入通道跨度，字节 | 共享 |
| 0x62c | input_zero，0～255 | 共享 |
| 0x630 | 旧 mode 接口，只允许 0 | 保留，无运算选择作用 |
| 0x628 | window 窗口描述 | 每任务，START 时快照 |

共享配置还受未排空结果/量化路径的占用约束。kernel 与 src 一样，不能在已有 CNN 工作占用时改写。相同卷积核的多个窗口可以连续入队；切换卷积核必须排空这一批。卷积核内部仍为 `cin × 9` 个 INT8 权重，硬件只递增通道地址，不计算输出通道编号。

新的窗口字从低位到高位为：

| 位段 | 字段 | 范围/含义 |
|---|---|---|
| [3:0] | count_minus_one | 0～15 对应连续 1～16 个输出位置 |
| [6:4] | row_mask | 三行输入有效掩码 |
| [7] | left_pad | 左边界填充 |
| [8] | right_pad | 右边界填充 |
| [15:9] | x | 输出起始列，0～127 |
| [22:16] | y | 输出行，0～127 |
| [31:23] | 输出元素偏移 | 0～511；RTL 旧字段名 dst_words |

输出元素偏移不是始终按字节或 word 计算：原始/量化 INT32 输出每元素 4B，可选量化 U8 输出每元素 1B。共享量化启用时，最终基址来自量化配置 dst。中间通道的部分和始终写 partial，不按此偏移选择缓冲位置。

提交顺序：配置共享输入、卷积核和几何参数 → 写 window → 向 CONTROL `0x600` 写 1。C 接口为 `npu_stream_configure(&cfg)` 和 `npu_stream_submit(window)`，后者不再接收卷积核地址。

FIFO 从 SD92 的 43bit 恢复为 **32bit**。x/y 各从 5bit 扩为 7bit；C 兼容描述符允许宽高到 128，但输入/输出张量仍需满足存储和别名检查，`npu_cnn_start` 仍要求整行窗口任务可被队列容纳。当前按最多 16 个位置分块，默认4项队列一次可容纳64个输出位置；更长行需分批入队，仍需满足数据空间与所有权检查。

## Matrix：精度与布局独立，全部随任务快照

| 偏移 | 字段 | 当前定义 |
|---|---|---|
| 0x108 / 0x10c / 0x110 | A / B / D | 输入及原始累加结果地址 |
| 0x114 / 0x118 / 0x11c | M / N / K | M/N=1～16，K≤256；ACCUMULATE 允许 K=0 |
| 0x130 | flags | bit0 转置 A；bit1 转置 B；bit2 累加原 D；其他位非法 |
| 0x134 / 0x138 | lda / ldb | 元素单位的 leading dimension，0 选择紧密布局，最大 4096 |
| 0x13c | precision | 0=有符号 INT8；1=有符号 INT16 |
| 0x140 | element_bytes | 内存每元素占 1、2 或 4B；INT16 不允许 1B |

没有 PACKED/INT16 组合标志。合法例子包括 INT8/1B、INT8/2B、INT8/4B、INT16/2B、INT16/4B。4B 槽位也只取低 INT8/INT16，不代表 INT32×INT32 乘法；累加器与原始结果始终为 INT32，溢出按低 32 位处理。

START 同时快照地址、维度、flags、precision、element_bytes 以及解析后的 lda/ldb。运行中可以为下一条任务修改这些 shadow，不会改变已提交任务。每条 Matrix FIFO 为 **96bit**。共享可选量化配置仍需等本来源队列排空才能改写。

C 描述符 `npu_gemm_descriptor` 现在显式包含 precision、element_bytes、lda、ldb。`npu_gemm_leading_dims()` 只为直接 MMIO 提交配置 shadow，`npu_gemm_start()` 使用其描述符中的 lda/ldb。

### Matrix FIFO 数据顺序

移除原来流模式强制 `rows=cols=1` 的处理。SRAM、RF、流输入均使用最多 4×4 的外积块；部分尾块只打开有效行列。

输入流不是可回读的行主序矩阵。它的顺序明确为：

```text
for tile_row in 0,4,8,...:
  for tile_col in 0,4,8,...:
    for k in 0..K-1:
      若 A 为流：先读本 tile 的有效 A 行，每行一个 32bit FIFO 字
      若 B 为流：再读本 tile 的有效 B 列，每列一个 32bit FIFO 字
    输出本 tile 的结果，先行后列
```

FIFO 每个操作数占一个字，取其低 INT8/INT16；不使用内存的 element_bytes 对流字进行字节打包。只有流侧采用上述顺序，SRAM/RF 侧仍按各自地址、转置和 lda/ldb 取数。可只将 A 或 B 接 FIFO，也可以双输入接不同 FIFO。生产者必须为每个 tile 重复提供被复用的流数据。

- D 写 SRAM/RF：按全局行主序地址写回，结果布局不变。
- D 或可选量化结果写 FIFO：按 tile 顺序输出，不隐式重排为整矩阵行主序。消费者需遵循同一顺序。
- 软件仍负责通道所有权和供数顺序；缺少输入或下游不消费会正常反压等待。

同时修正跨度检查：流端点是通道，不是连续字节数组；不同通道不会因为虚拟矩阵跨度较大而被误判为重叠。

## Vector：任务控制与程序指令分开

任务控制字 `0x214`：

| 位段 | 定义 |
|---|---|
| [4:0] | 直接运算 opcode |
| [5] | 程序模式 |
| [6] | INT8 SIMD；否则 INT32 |
| [7] | 直接模式的标量 B 输入 |
| [8] | 程序模式的 U8 打包输出 |

bit7 不再同时表示输出打包。程序模式当前只允许 `0x20`（INT32）、`0x60`（INT8 SIMD）及 `0x120`（INT32 运算、U8 打包输出），旧 `0xa0` 会被拒绝。直接模式不允许 bit8。Vector FIFO 随此从 98bit 变为 **99bit**。

VPG3 的一条程序指令仍为 **32bit**，低位到高位排列为“操作与立即数选择 → 目的与源寄存器 → 立即数”：

| 位段 | 字段 |
|---|---|
| [4:0] | opcode |
| [5] | 普通 ALU 的 B 操作数使用立即数 |
| [7:6] | rd |
| [9:8] | ra |
| [11:10] | rb |
| [31:12] | immediate20 |

普通 ALU 的立即数为有符号 20bit；SIMD 使用立即数的低字节广播。LD32 使用 `ra + signed immediate20`。SHRD/RSHRD 使用 ra/rb 两个寄存器，右移量直接放 immediate20，限制 0～32，不替换高字寄存器为立即数。SCALAR 从任务 scalar 读值。各 opcode 数值保持原有定义。

16 条程序指令、4 个临时寄存器、程序数量和循环起点的含义不变。程序配置仍为共享，只能在 Vector 排空后修改。C/Python 的指令生成器与测试编码器均已迁移。


## 当前验证入口

默认配置和性能使用[项目首页](../../README.md)；当前版本的功能、综合、最终PNR及检查证据统一见[报告索引](../reports/README.md)。
