# CPU 发令、搬运与计算流水

CPU 程序存放在两块共享 SRAM 的 bank0；参数只有 bank1 中的一份。硬件没有指令 RAM、微程序 PC 或层执行状态机。PE 的四个架构寄存器、两路邻居读与本地写规则保持不变。流单元只搬数据，量化全部由 PE 指令完成。

## 一条命令同时计算和换入操作数

ABI 3 在寄存器格式指令的低 9bit 中编码并行搬运控制。下面是卷积的启动和稳态序列，FC 用 PREFETCH／COMMIT 启动后进入相同 bundle 流水。稳态一条 32bit MMIO 写同时执行三件事：

1. 使用当前 R2/R3 做 MAC，累加到本 PE 的 R0。
2. 将输入缓冲中下一组激活／权重提交到本地 R2/R3。
3. 启动再下一组激活／权重的预取。

```text
NEXT(term0)                       // 首项直接装入 R2/R3
PREFETCH(term1)                   // 缓冲下一项，保持当前 RF
MAC(term0) + COMMIT(term1) + PREFETCH(term2)
MAC(term1) + COMMIT(term2) + PREFETCH(term3)
...
MAC(term N-2) + COMMIT(term N-1)   // 关闭 advance，不超读 shape 末尾
MAC(term N-1)                     // 普通指令排空
```

算术与提交在同一沿上读取旧值、写入新值。算术行 mask 描述当前项，低 4bit 的预取行 mask 描述再下一项；提交使用缓冲记录的目标行 mask。两者独立处理 padding。算术目的与加载目的寄存器不能相同，非法组合报错且不执行。输入未准备好时命令 ready 反压；CPU 不轮询状态猜测 SRAM 延迟。

最后一个 SRAM 响应可直接前递到同沿的提交路径，消除额外 buffer-valid 等待。发起下一次传输的控制优先于本次完成清除，连续接力时不会误清 busy。缓冲复用原有每口四个 gather 数据锁存器，合计 2×4×32bit；没有新增 PE 架构寄存器或第三块 SRAM。

单独的 PREFETCH/COMMIT/EXCHANGE（60/59/58）仍可使用。异步预取仅支持 ROW/COL load，每端口最多一个上下文；FULL load/store 继续使用 NEXT。普通 NEXT 按寄存器号阻塞有 RAW/WAW 冲突的算术命令，也检查邻居读。配置与 ARM 等待未消费的输入缓冲清空。

## 软件压缩配置与循环

`tools/torus_schedule.py` 只根据模型几何生成 161 个 tile 的元数据和 19 种边界模板，没有输入样本、预测值或硬件微程序。全部元数据和原生 RV32IMC 指令位于 CPU SRAM。

- 每次推理首层完整写描述符，后续层采用编译器计算出的配置差量。固定四行 tile，用运行时 mask 屏蔽尾块，避免反复修改形状。
- BASEPAIR 命令一次更新输入／输出两个基址并重置上下文游标。其作用只是 I/O 地址控制。
- bias 每 tile 装载，倍率 R1 每输出通道组装载一次。相同边界模板命令保留在 CPU 寄存器，不再逐项读取 SRAM 命令表。
- 原生驱动每层保存一次 CPU callee-saved 寄存器。输入通道循环展开，CPU 采用压缩 SW 指令减少取指。FC 的发令循环按 8 项展开。
- 首层编译期将输入零点折入 bias：`B′=B−17×Σ有效权重`，依边界生成 32B 常数。左边界 CPU 只复制两个 bias 常数到 PE，本次模型无需运行期 SUB。输入编码、原始权重和量化语义保持不变。

实际每推理描述符字段写为 445 次，含 BASEPAIR 每次计两个字段；与旧版每 tile 写全描述符的静态 8372 次计数相比减少 94.7%。这个比较包含配置策略改变，不能把全部收益归因于流水。

## SRAM 与缓存

硬件仍是两个物理同步单端口 SRAM，总计 16KB。激活和唯一一份参数共享 bank1，同 bank 请求须仲裁；逻辑上的两路流端口不等于两个物理读端口。

当前面积优先配置采用每口 32-word cache，合计 256B 数据；写操作只失效同 word 的缓存项，包括与当前 fill 的冲突。保留权重 cache 填充；无关的 CPU mailbox/JTAG 写不会冲刷整口 cache。每口还有独立 gather 锁存器，cache 冲突不会破坏本次四 lane 收集的数据。

当前 cache 每口四个 bank，低两位 word index 选 bank，其余 index 选 bank 内行。同 word 请求合并；同 bank 不同 word 的请求通过现有 gather 缓冲分次完成。只有已经查询并确认 miss 的 word 才发起 SRAM 请求，避免将尚未轮到查询的 lane 当成 miss。MNIST 常用连续字节访问保持原 32-word 版本周期。

相同软件的单样本对照：32 words/口为 20233 周期，64 words/口为 19258 周期，均含 CPU argmax。用户接受约 20233 周期后，面积优化默认采用 32；本轮回归上限设为严格小于 20300，覆盖 argmax 引起的少量差异。旧的小于 20k 结论只针对先前显式 64-word/口配置。

所有六层仍通过流单元写回共享 SRAM；当前没有跨层融合，也没有依靠 torus 转发消除中间写回。中间层可直接观察或复制快照，快照复制本身计入相应调试程序的耗时。

## 如何读性能计数

`overlap` 统计活动预取期间接受的非零行 mask PE 运算。当前 32-word/口单样本为 3385；它证明搬运与计算实际重叠，不能直接解释为节省的周期数。新 bundle 会等到缓冲完成再提交／启动下一项，所以测试台“SRAM 读请求被接受与 ALU 同周期”的计数可以为零；这个请求指标不覆盖读响应周期，也不能否定重叠。

`cycles` 包括六层、实际 SRAM 写回和 CPU argmax；`layer_cycles` 在 argmax 前读取。测试台另外从真实 CPU mcycle 读事件之间独立计时钟，检查二者一致，并可通过 `--max-cycles 20300` 强制两项严格小于阈值。JTAG 上传、自测与最终完成报告不属于推理计时。

旧 ABI 2 的同软件串行／预取 A/B 数据见 [validation-v2.md](validation-v2.md)。ABI 3 记录见 [validation-v3.md](validation-v3.md)，当前 ABI 4 的结果和源码哈希见 [validation.md](validation.md)，不要将跨版本总收益全部归因于某一项改动。
