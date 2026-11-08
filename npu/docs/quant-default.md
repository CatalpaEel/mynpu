# 默认推理使用共享 QT01 量化

当前已[取消配置写入的忙时/排空限制](software-owned-config.md)，采用单套共享配置、由软件控制一致性；下述硬件写保护现状属于此前版本。

当前数量编码已更新为 [SD95 count1～16](count16.md)，默认共享量化为 23,937 周期/图；下述旧双缓冲方案未实现，配置仍为单套。

默认共享量化保持不变；当前窗口已升级为 [SD94 count−1](count-minus-one.md)，默认镜像和最新验证以该文档为准。下述字节对照对应升级前的 SD93。

当前 `npu/mnist/firmware.py` 在未设置环境变量时默认启用共享 QT01。生产 artifacts 已重生成：CNN/Matrix 原始结果进入共享量化流水线，软件配置每通道参数；完成等待使用独立 IRQ/WFI。硬件复位仍从 INT32 旁路状态开始，固件在加载有效量化参数后使能 QT01。

默认镜像与此前已测试的 `npu/build/command-v1-quant-artifacts` 在 boot 汇编、二进制、hex、测试元数据及十组 SRAM 镜像上逐字节一致。当前默认周期为 26,067/图。

验证使用默认 artifacts、未传 `--artifacts-dir`：

```bash
python3.12 npu/scripts/run_vcs.py --suite blocking --tag quant_default --macro
python3.12 npu/scripts/run_vcs.py --suite quantlayers --tag quant_default --macro
python3.12 npu/scripts/run_vcs.py --suite jtag --tag quant_default --macro
```

结果索引为 `npu/reports/quant-default-validation.json`。

## 配置排空限制：现状与可行的取消方式

本次只修改默认固件选择，没有修改硬件配置生命周期保护。

Matrix 普通任务的地址、维度、精度、存储间距、lda/ldb 已在 START 时快照，允许提前修改下一任务的 shadow。仍需排空的主要是 CNN 共享输入/卷积核/几何参数、各来源的共享量化参数，以及 Vector 共享程序表。

CNN engine 虽会在任务启动时锁存几何配置，但还在 FIFO 中的窗口任务没有配置版本。直接取消写保护，会让旧窗口任务取到后来写入的 src/kernel 等参数。量化参数还会影响 enable、输出格式和目标地址，必须与生成结果的批次保持一致。

可采用两套共享配置上下文 A/B，而不是把完整配置塞回每个任务：

1. 当前批次引用 A。软件在 B 中准备下一批的 CNN 配置与量化参数。
2. 提交下一批窗口时，FIFO 额外快照一位 context ID。32 位窗口编码本身不需要改变；CNN FIFO 则从 32bit 变为 33bit。
3. 硬件按 context ID 选择配置；旧结果完全写回后才能释放该上下文。量化流水线中的结果也要保留所属上下文直到排空。
4. 软件可以继续向 B 批次排队，无需等待整个 CNN 队列清空；A 释放后，可准备再下一批。

这样取消的是“整条队列必须为空”，仍禁止覆盖被队列、活动任务或待写回结果引用的上下文。只有两套上下文都占用时，才需要等待其中一套释放。

CNN 与量化配置应一起采用上下文，单独双缓冲 kernel 无法隐藏量化换参等待。Matrix 若希望跨量化参数批次排队，也需要给任务增加对应的量化 context ID；Vector 程序表可以独立采用相同机制。

需要增加配置寄存器、索引、多路选择和占用跟踪，面积及性能收益必须实测。该双缓冲方案尚未实现，当前 RTL 仍保留排空保护。
