> 实现专题：文中阶段性队列、周期和面积仅适用于当时快照。当前默认配置及最终结果见[项目首页](../../README.md)；接口字段以当前 RTL / `npu/sw/npu.h` 为准。

# 配置修改时序交给软件

CNN、Matrix、Vector 与共享 QT01 的配置允许在运行中或有排队任务时写入。取消的是配置一致性的 busy/排空写保护；没有新增双缓冲、配置版本、暂停派发 CSR 或自动屏障。FIFO 仍为 CNN/Matrix/Vector 各 8 项，条目分别为 32/96/99bit，RF 仍为 256B。

新增只读启动、量化采样与写应答计数，详见 软件可见同步与执行进度（历史文档已移除）。这些观测不增加配置保护。

当前量化消费与写合并的边界见 [SYNC v2](throughput-optimization.md)：dst/pack/enable在ISSUED之前实时读取，ISSUED之后的已缓冲写地址固定，WRITTEN仍等待真实应答。

## 写入与生效规则

| 配置 | 何时读取 | 修改后的影响 |
|---|---|---|
| Matrix 地址、维度、精度、间距、lda/ldb | START 提交时快照到任务 FIFO | 已提交任务不变，后续提交使用新 shadow |
| CNN 输入、卷积核、几何参数 | 窗口任务实际派发时锁存 | 当前活动任务不变，尚未启动的窗口读取最新配置 |
| Vector 地址、长度、模式、scalar | START 提交时快照到任务 FIFO | 已提交任务不变 |
| Vector program count/loop | Vector 任务启动时锁存 | 当前任务使用原数量/循环起点，尚未启动的任务读取新值 |
| Vector program words | 每条指令执行时读取 | 运行中的程序也可能立即执行新指令 |
| QT01 multiplier/bias/shift/zero/clamp/input_offset | 每个结果被量化流水线接收时采样 | 已接收结果保留原参数，之后接收的结果使用新值 |
| QT01 enable/pack/dst | 路由与写回实时读取 | 可以改变正在等待的结果的旁路、打包方式或目的地 |

一组配置仍通过多次 32bit 写入更新，硬件不提供整组原子切换。写入成功只表示该寄存器接受了新值，不表示某一批任务一定使用同一版本。CPU 必须自行安排配置、提交、数据供给和结果接收的顺序。

例如，最后一个旧 CNN 窗口已经派发、后续任务尚未启动时，可在旧窗口仍等待输入/计算时准备下一窗口配置。但它的旧量化结果可能还没有被量化单元采样，此时不能据此推断修改量化参数也符合预期。默认固件继续使用完成计数和 IRQ/WFI 做原有同步，开放写入本身不自动改变软件调度。

软件可以有意改变排队或活动任务的行为。错误时机可能造成混用参数、写到非预期位置、任务报错或不能继续前进；不增加硬件一致性恢复机制。

## RTL 与软件接口

- `npu_stream_control.sv` 删除 CNN 配置写入的 busy/pending 限制，移除只服务于这项保护的 pending 输入。原有 dispatch backpressure 不变。
- `npu_mmio.sv` 删除 Vector 程序配置/程序表的 vec_occupied 写入限制。Matrix shadow 本来就可运行中修改，保持既有任务快照方式。
- `npu_shared_quant.sv` 删除来源 busy 对量化配置写入的限制及对应输入。
- `npu_stream_configure()`、`npu_vector_program_configure()`、`npu_quant_configure()` 不再查询 busy 来拒绝配置。它们不会等待或暂停硬件；量化批量配置函数仍按原步骤先关闭 enable 再写入参数，调用时机也由软件负责。

本次不改变 START、ACK、CLEAR 的既有语义。只读寄存器、字段范围/地址合法性、故障恢复与 FIFO 满空处理仍按原协议工作，不属于本次移除的配置时序限制。

Operator ABI 的 minor 版本为 **2.2**：`0x40000040` 返回 `0x00020002`。新增只读能力寄存器 `0x40000080`，返回 `0x0000000f`：

| 位 | 表示支持运行中配置写入 |
|---|---|
| 0 | CNN 共享配置 |
| 1 | Matrix 任务 shadow |
| 2 | Vector 程序配置/程序表 |
| 3 | QT01 参数 |

SD95 数量编码、VPG3 指令编码、Matrix 4 格式和 QT01 算术 ABI 不变。默认共享量化 boot 二进制与提交 `65ea66f` 完全一致，仅模型元数据更新为 Operator ABI 2.2。

## 本功能初次实现时的验证（edbb4ce，历史记录）

运行 `python3.12 npu/scripts/collect_software_config_validation.py` 审核结果和依赖 SHA，生成 `npu/reports/software-config-validation.json`。

15 组 VCS 回归及 657 项 C 软件检查通过。新增 `softcfg --macro` 有 27 项结果检查，通过 FIFO 制造确定的等待阶段，验证实际数据行为：

1. CNN 活动窗口等待输入时，修改 src/kernel/dst；活动窗口得到旧结果 12，已排队窗口得到新结果 27。
2. Vector 活动任务与排队任务共存时改程序表及 count；活动任务按旧 count 执行新指令得到 12，后续任务按新 count 得到 26。
3. Matrix 等待输入时修改量化参数和目的地，结果按新参数写到新地址。
4. 量化结果被满 FIFO 阻塞时改算术参数，已经接收的结果仍为旧值 36；改目的地后该结果写入新地址，FIFO 原内容保持不变。下一结果使用新参数得到 120。

另覆盖深度 8/16 队列、共享量化、CNN Stream、Vector 程序、单元间流转发、共享操作数与 IRQ/WFI。默认推理 10 张图、60 个逐层张量共 17,940B 一致，JTAG 42 项检查通过，仍为 **23,937 周期/图**。

没有重跑综合或布局布线，当前面积和时序尚未重测。
