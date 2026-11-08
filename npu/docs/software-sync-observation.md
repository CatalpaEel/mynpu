# 软件可见同步与执行进度（SYNC v1 历史接口）

当前为 [SYNC v2 与吞吐优化](throughput-optimization.md)：地址保留，新增写取消计数；量化提前接收，ISSUED表示Stream/写合并接收，成功/失败应答按结果元素数累计。以下记录6697d58的旧握手语义和验证结果。

这些只读 MMIO 允许软件观察任务派发、量化参数采样与写回完成，安排运行中修改配置。没有配置锁、双缓冲、自动等待或新的暂停机制。现有 START/ACK/CLEAR、任务 FIFO 编码和计算路径不变。

地址表均为相对 `0x40000000` 的字节偏移。`0x084` 返回 `0x0001003f`：高 16 位版本 1；低位依次表示启动计数、启动提交编号、引擎故障/取消计数、执行状态、量化进度计数、量化写应答计数。C 定义在 `npu/sw/npu.h`。

## 任务生命周期

| 只读字段 | Matrix | Vector | CNN | 含义 |
|---|---:|---:|---:|---|
| SUBMITTED（原有） | 12c | 22c | 660 | START 被接受的累计次数；不计拒绝提交 |
| STARTED | 144 | 238 | 634 | 引擎实际启动、锁存活动配置的累计次数 |
| STARTED_TICKET | 148 | 23c | 638 | 最后启动任务的提交编号，从 1 开始；复位值 0 |
| COMPLETED（原有） | 128 | 228 | 65c | 成功完成任务次数 |
| FAULTS | 14c | 280 | 63c | 活动任务故障次数；CNN 终止后尾随的错误应答不重复计数；不计非法 CSR/提交 |
| CANCELLED | — | — | 648 | CNN 故障时被清空、尚未启动的任务数 |
| OBSERVE | 150 | 284 | 64c | 执行位置/流水线实时状态，见后表 |
| SYNC_STATE | 154 | 288 | 650 | 当前引擎与派发信号 |

Matrix/Vector 的 FIFO pop 比实际启动早一个周期，STARTED 按真正的引擎启动边沿计数。只看 FIFO 空不足以确认配置已锁存。

CNN 故障清空等待队列。举例：提交 1、2，1 启动后故障，2 被取消，恢复后提交 3 并启动：STARTED=2、STARTED_TICKET=3、FAULTS=1、CANCELLED=1。**不能用启动次数或完成次数代替提交编号跨故障同步。** Matrix/Vector 保持原有故障处理；不会新增清空策略。

SYNC_STATE 位：0 busy，1 start/launch，2 队列非空，3 done 原始事件，4 fault 原始事件，5 原有 dispatch blocked（Vector 恒 0）。事件是瞬时值，低速轮询可能错过；可靠事件记录使用累计计数和原有 sticky 状态/IRQ。

## 量化生命周期

CNN 基址 `0x700`，Matrix 基址 `0x740`。这些寄存器按来源分别统计，只统计经过共享 QT01 的结果；原始 INT32 旁路不增加量化计数。

| 相对来源基址 | C 字段 | 含义 |
|---:|---|---|
| 24 | NPU_QUANT_ACCEPTED | QT01 内部首次接收输入并采样算术参数 |
| 28 | NPU_QUANT_ISSUED | 量化输出被消费，写请求获得 grant |
| 2c | NPU_QUANT_WRITTEN | 对应量化写请求收到成功应答 |
| 30 | NPU_QUANT_WRITE_ERRORS | 对应量化写请求收到错误应答 |
| 34 | NPU_QUANT_FLUSHED | 尚在 QT01 中的结果被 flush 丢弃 |
| 38 | NPU_QUANT_SYNC_STATE | 实时采样、拥有者、反压等状态 |

QT01 的原输入 ready 在输出被消费时才应答给生产者，因此 **ACCEPTED 按内部首次采样统计，不按输入 valid&&ready 统计**。满 FIFO 阻塞输出时，ACCEPTED 可以领先 ISSUED；写 grant 后，ISSUED 可以领先 WRITTEN。SRAM/RF/FIFO 的成功写应答才增加 WRITTEN，不表示后续消费者已经读取该结果。

每个写请求在 grant 时保存“是否量化输出”的小标签；随后软件修改 enable，也不改变该写应答的分类。CNN 两条写通路同周期应答时可以增加 2。错误应答不增加 WRITTEN；flush 不伪造写成功。FLUSHED 只统计被丢弃的 QT01 在途结果，不统计引擎内全部未完成工作。

量化 SYNC_STATE：bit0 enable、1 pack、2 本来源占有 QT01、3 输入 valid、4 输出 valid、5 输出 ready、6 flush、7 本周期有成功写应答、8 有失败写应答；[11:9] 全局状态（0 空闲、1 加偏置、2 等待输出）、12 忙时 owner（0 CNN/1 Matrix）、13 本周期采样事件、14 本周期输出握手；其余为 0。

## 执行位置 OBSERVE

这些字段暴露当前实现的调度位置，不是新的任务/指令格式。IDLE 时位置寄存器可能保留上一次任务的值；应先看 busy。busy 时也不代表该字段已完成或不会继续推进。

| 单元 | 位段 | 含义 |
|---|---|---|
| CNN | [2:0] | 状态：IDLE=0、START=1、WAIT_INPUT=2、RUN=3、DRAIN=4 |
| | [6:3] / [14:7] / [19:15] | 窗口 position / 输入通道 cursor / 当前任务窗口数 |
| | 20 / 21 / 22 | 最终输出 / 普通端口有应答在途 / RF 写在途 |
| | 23 / 24 / 25 / 26 | gather 在途 / partial seed 在途 / 过滤后结果有效 / 原始结果待处理 |
| | 27 / 28 / 29 / 30 / 31 | 本周期计算接收 / quant enable / pack / 普通端口 req / busy |
| Matrix | [3:0] | IDLE=0、CLEAR=1、FETCH=2、WAIT_WORDS=3、C_REQ=4、C_WAIT=5、EMIT=6、D_REQ=7、D_WAIT=8 |
| | [12:4] / [17:13] / [22:18] | K 内循环 / tile 行起点 / tile 列起点 |
| | [24:23] / [26:25] | tile 内输出行 / 列 |
| | 27 / 28 / 29 / 30 / 31 | A 流输入 / B 流输入 / D 流输出 / req / busy |
| Vector | [3:0] | IDLE=0、A_REQ=1、A_WAIT=2、EXEC=3、LOAD_REQ=4、LOAD_WAIT=5、OUTPUT=6、D_REQ=7、D_WAIT=8 |
| | [8:4] / [13:9] / [18:14] / [27:19] | 当前程序 PC / 锁存的指令数量 / 循环 PC / 任务 mode |
| | 28 / 29 / 30 / 31 | req / we / SIMD mode / busy |

## 如何不排空队列地修改

- **Matrix shadow**：提交时快照，本来就可以直接准备下一任务，不需要等待 STARTED。
- **CNN 共享几何与输入/核地址**：确认最后一个旧配置任务的 STARTED_TICKET 已达到目标后，活动任务已锁存旧配置，可以准备后续配置。但还没启动的旧任务会读到新配置；如果后续任务已经能立即启动，多次 MMIO 写之间可能被它采样。软件需要通过提交顺序或已安排的数据依赖留出窗口。
- **Vector count/loop**：启动后已锁存，可为后续任务更新。**指令表仍是执行时实时读取**，STARTED 不保证指令表已用完。PC 观察只能帮助分析，不能锁住 PC；只有软件安排的停顿/依赖确保不再读取旧表时才适合改表。
- **量化算术参数**：记录本批结果数量及基线，ACCEPTED 达到目标后，这些结果的乘数、偏置、移位、零点、上下限与输入修正已锁存，可以修改下一批算术参数。前提是下一批结果不会在多次参数写入中间被接收。
- **量化 enable/pack/dst**：仍然实时生效。ACCEPTED 不保护路由字段。切换应结合 ISSUED/WRITTEN 和生产者进度，确认无旧输出还会使用它们；WRITTEN 达到旧批目标也不能阻止新批紧接着输出。

例如，软件可以先提交一个等待输入 FIFO 的后续任务，使它启动后无法产出；等待旧批量化 ACCEPTED 达标，逐项更新算术参数，然后供给新输入。这样计算任务可以在队列非空时切换参数，而不用硬件替软件判断配置时序。

所有计数器为 32bit，按模 2^32 回绕，仅系统复位清零；ACK/CLEAR 不清累计计数。`npu_counter_reached(observed,target)` 支持回绕比较，前提是相隔少于 2^31 个事件。多寄存器读取没有原子快照；软件应检查故障/取消并在恢复后重新建立基线。它们提供观察能力，不提供原子修改窗口。

## 验证与面积

15 组 VCS 回归与 663 项 C 接口检查通过；默认 10 张 MNIST 均为 23,937 周期，60 个逐层张量共 17,940B 一致，JTAG 42 项检查通过。结果由 `npu/scripts/collect_sync_observation_validation.py` 按当前源文件 SHA 审核生成，见 `npu/reports/sync-observation-validation.json`。定向测试覆盖启动/编号、排队取消、readonly、量化反压/采样、发出与写应答分离、双应答、flush、错误、回绕及复位；另回归默认 MNIST 和单元协议。

新增 20 个 32bit 累计/编号寄存器（总计 640bit）和 3 个写分类标签；实时 OBSERVE/SYNC_STATE 为组合读出。不扩宽任务 FIFO，不增加配置副本或数据缓存。尚未重测本次修改后的综合/PNR面积时序；历史 `edbb4ce` 的 2.547215mm² 不代表本次结果。
