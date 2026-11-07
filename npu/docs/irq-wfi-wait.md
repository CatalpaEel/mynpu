# 共享量化固件：用完成中断唤醒WFI

已在 `NPU_SHARED_QUANT=1` 的单图固件中默认启用完成中断等待。RTL没有修改，也没有新增ISR、寄存器或存储；此前18ns＋门控面积/静态时序仍对应同一RTL。本轮不重跑综合。通用Vector路径生成的boot.bin、boot.hex、params.hex、test_meta.svh均与原来逐字节相同。

## 机制与正确性

继续使用现有IRQ16（CNN完成/错误与Matrix完成/错误共享）。`mie[16]=1`，`mstatus.MIE=0`：CV32E40P的唤醒信号来自 `irq_i & mie`，因此中断可以唤醒WFI，但不会跳转trap handler。CPU醒来后在原程序中复查完成票据，而不是把IRQ电平当成“所有任务已完成”。

CNN等待流程：

```text
target = submitted
loop:
    写 control.bit3，清除 sticky done（不清故障或完成计数）
    检查 fault
    如果 completed == target，结束
    WFI
    跳回 loop
结束时再清一次 done，避免IRQ16切到Matrix时仍被CNN保持为高
```

清标志必须在读完成票据之前。若完成发生在清标志之前或同拍，后续票据读能看到完成；若发生在票据读之后到WFI之间，sticky IRQ保持挂起，CPU不会无限睡眠。当前CPU/MMIO按顺序处理这几个访问。

Matrix的bit1清除仅允许在空闲时执行，不能像CNN那样在有队列任务时反复确认。因此Matrix在完成位尚未挂起时先WFI等一次中断；醒来后若仍有任务未退休，用短轮询收尾，全部完成后再清bit1。它不是完全无轮询的Matrix完成路径。故障检查保留，没有修改硬件接口来强行清运行中的完成位。

## 实测

三种方案均使用相同RTL、参数、10张输入和golden。周期不含输入装载。两条中断方案的功能均正确；默认选更快的“完成等待IRQ”，队列满IRQ为可选实验。

| 方案 | 周期/张 | 50MHz推理时间 |
|---|---:|---:|
| 原轮询 | 27,432 | 548.64µs |
| 完成等待IRQ＋WFI（默认） | **26,092** | **521.84µs** |
| 完成等待＋CNN队列满都IRQ/WFI | 26,150 | 523.00µs |

默认减少 **1,340周期（4.88%）**，仍未达到20k。队列满IRQ比默认慢58拍，所以不默认启用。

| 每张统计 | 原轮询 | 默认完成等待IRQ |
|---|---:|---:|
| WFI系统周期 | 3 | 6,929 |
| CPU取指等待 | 5,214 | 2,926 |
| CPU MMIO访存等待 | 4,153 | 2,676 |
| CPU取指请求未获grant | 7,626 | 4,340 |
| CNN普通SRAM请求未获grant | 4,554 | 2,620 |
| 上述等待中同bank被CPU取指接受 | 4,424 | 2,490 |
| 完成等待代码的活跃PC占用 | 9,107 | 3,324 |
| 队列空间轮询PC占用 | 4,502 | 4,502 |

CPU取指造成的CNN同bank等待减少 **43.72%**。事件计数与周期状态有重叠，不能相加，也不能把等待减少量直接当成净推理收益。改完后 `completion_poll` 计数实际是等待代码的活跃PC占用，包含清中断和复查票据，不再全部是连续忙轮询。

| 层 | 原轮询 | 默认完成等待IRQ | 变化 |
|---|---:|---:|---:|
| Conv1 | 2,737 | 2,757 | +20 |
| Conv2 | 6,941 | 6,865 | −76 |
| Conv3 | 7,353 | 6,153 | −1,200 |
| Conv4 | 3,401 | 2,945 | −456 |
| Conv5 | 3,833 | 4,089 | +256 |
| FC及后处理 | 3,028 | 3,144 | +116 |
| 分类收尾 | 139 | 139 | 0 |

并非每层都加速：中断确认、额外检查和WFI唤醒会付出开销；原本竞争较小的层可能退化。目前仍有队列空间轮询、Matrix尾部轮询、激活供数与量化结果反压，不能声称瓶颈已经全部消除。

## 验证与复现

[机器验证报告](../reports/irq_wait_validation.json)核对所有测试输入/RTL/固件哈希：三种方案各10张图，默认方案60个中间层张量（17,940字节）逐字节匹配golden，JTAG 42项检查通过；同一18ns保层级门控网表执行默认固件的一张MNIST，分类和10个logits正确，端到端周期也与RTL一致。门级检查为零延迟、无SDF，不是物理时序签核。

默认固件：[汇编](/home/s2400012841/chip-fullstack-2026/mynpu-softpe/npu/build/irq-artifacts/boot.S)、[字节镜像](/home/s2400012841/chip-fullstack-2026/mynpu-softpe/npu/build/irq-artifacts/boot.hex)。实际指令从600条增加到657条，程序仍放在原SRAM分区内。

先准备包含model/params/input/golden的独立artifact目录，再运行生成器；不要覆盖需要保留的对照文件：

```bash
# NPU_SHARED_QUANT=1时，完成等待IRQ默认开启，CNN队列满IRQ默认关闭。
NPU_ARTIFACTS_DIR=/path/to/artifacts NPU_SHARED_QUANT=1 python3.12 npu/mnist/firmware.py
python3.12 npu/scripts/run_vcs.py --suite blocking --macro --tag MY_IRQ --artifacts-dir /path/to/artifacts
```

对照开关：

- `NPU_QUANT_IRQ_WAIT=0`：完整恢复旧轮询二进制。
- `NPU_QUANT_IRQ_WAIT=1`：默认完成等待IRQ/WFI。
- `NPU_QUANT_QUEUE_IRQ_WAIT=1`：另把CNN队列满等待改成IRQ/WFI；清done后重读队列占用，避免丢失空位事件。本实验慢58拍，保留为可选。

本次artifact目录为 `npu/build/irq-poll-artifacts`、`npu/build/irq-artifacts`、`npu/build/irq-full-artifacts`。已验证原通用Vector固件不变；本轮没有改默认后处理算子的选择。
