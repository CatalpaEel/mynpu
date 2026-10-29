> 历史记录：优化前的串行版本，当前结果见 [validation.md](validation.md)。

# 验证记录

2026-10-29，VCS Q-2020.03-SP2-7，`experiment/torus-register-file` 工作区。

| 验证 | FPGA BRAM 功能模型 | ASIC SRAM 功能模型 |
|---|---|---|
| 定向单元测试 | 1706 项通过 | 1706 项通过 |
| MNIST 8 个记录样本 | 14352 个逐层输出字节全部一致 | 14352 个逐层输出字节全部一致 |
| 逐层快照读回 | 首个样本六层全部通过 | 首个样本六层全部通过 |
| CPU 连续命令吞吐测试 | 连续 64 周期各接受一条命令，结果正确 | 连续 64 周期各接受一条命令，结果正确 |
| CPU/JTAG | SBA 装载、并发无关地址读写、halt/resume 通过 | 同左 |

PE 测试覆盖本地写目的、两路独立邻居读寄存器、四向环绕、四行 mask、32bit 命令连续接受、INT8/16/32 乘加及 MULHR。流测试覆盖负／零 stride、三层外部 shape、寄存器号的外层步进与循环、ROW/COL 广播、FULL 转置遍历、8/16/32bit 打包、符号扩展、PE 起点环绕、物理行 mask、同口多上下文、双口争用、cache 冲突与失效、byte enables，以及非法读源／操作码／地址／对齐错误。

MNIST 的独立整数 golden 使用原始导出模型的参数、INT32 累加回绕和原始 shift=31；硬件参数像仅将倍率 M 改为 2M，由 PE 的 MULHR 执行相同缩放。8 个样本的整数 golden 与已有记录 PyTorch 最终输出最大差 1 个 code。本次没有重新运行 PyTorch 或重新评估完整数据集准确率。

CPU 程序大小 2704B，参数像 4288B；运行时只有两块物理 8KB 单端口共享 SRAM。

## 当前性能和未完成指标

在本回归条件下，两个存储后端的 8 个样本均为 **167828 个 CPU mcycle／次**，关闭逐层快照。计时包含软件描述符配置、循环、PE 计算、量化和层写回，不包括 JTAG 上传输入；回归期间有并发无关 SBA 访问与状态轮询。

这是功能已跑通的初版，**未达到约 20000 周期目标**。64 周期连续命令测试证明接口吞吐能力，不能代替整个推理的吞吐。当前性能仍受 CPU 配置／边界处理／发令及搬运与计算串行执行影响；需要继续优化软件调度和搬运开销。

本次没有综合或布局布线结果。ASIC 测试关闭 SRAM 宏 timing checks，只验证功能，**不证明 50MHz 可实现，也不证明能装进 2mm×2mm**。未做功耗分析或 FPGA 板级测量。

## 证据

每项 result.json 都记录通过状态、实际输出、源文件及资产 SHA256、运行期间是否发生变更。以下路径指向当前服务器的运行产物：

- [unit-fpga result](../../build/torus/baseline-serial-v1/unit-fpga/result.json) · [run.log](../../build/torus/baseline-serial-v1/unit-fpga/run.log)
- [unit-asic result](../../build/torus/baseline-serial-v1/unit-asic/result.json) · [run.log](../../build/torus/baseline-serial-v1/unit-asic/run.log)
- [soc-fpga result](../../build/torus/baseline-serial-v1/soc-fpga/result.json) · [run.log](../../build/torus/baseline-serial-v1/soc-fpga/run.log)
- [soc-asic result](../../build/torus/baseline-serial-v1/soc-asic/result.json) · [run.log](../../build/torus/baseline-serial-v1/soc-asic/run.log)
- [soc-fpga-tapall result](../../build/torus/baseline-serial-v1/soc-fpga-tapall/result.json) · [run.log](../../build/torus/baseline-serial-v1/soc-fpga-tapall/run.log)
- [soc-asic-tapall result](../../build/torus/baseline-serial-v1/soc-asic-tapall/result.json) · [run.log](../../build/torus/baseline-serial-v1/soc-asic-tapall/run.log)

构建资产：[manifest.json](../../build/torus/assets/manifest.json)、[CPU ELF](../../build/torus/assets/cpu.elf)、[CPU hex](../../build/torus/assets/cpu.hex)、[模型参数像](../../build/torus/assets/model.hex)、[逐层 golden](../../build/torus/assets/golden.hex)。

`build/` 产物由 Git 忽略，可按教程命令重建。没有提交或推送，也没有修改原有三个工作区的 RTL。
