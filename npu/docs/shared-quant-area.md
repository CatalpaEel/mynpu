# 共享量化版综合面积

以下为旧点积Matrix版的综合记录；当前[4×4外积版面积时序](matrix-outer4-area.md)已另行测量。

源码 `a04d1d0`，对照为加入量化前的 SIMD 检查点 `d4a89a9`。

| 项目 | 面积 mm² |
|---|---:|
| 当前默认优化总面积 | 2.586795 |
| 标准单元 | 1.783907 |
| 两块 SRAM 宏 | 0.802887 |
| 加量化前同配置总面积 | 2.435705 |
| 净增加（含接口改动） | 0.151089 |

相对基线净增加 6.20%。保留层级版的共享量化模块自身为 **0.135909mm²**，包括参数寄存器、仲裁、乘法、舍入和裁剪。

默认版在20ns报告约束下，系统时钟setup slack **+4.0014ns**，TNS 0.0000ns，违反路径0。属于综合估算，尚未重新布局布线。

模块分布使用保留层级版；它与默认优化版存在跨层级优化差异，分项不与默认版总数混加。

| 保留层级版模块 | 面积 mm² |
|---|---:|
| SRAM macros | 0.802887 |
| XBAR | 0.419819 |
| CPU | 0.294394 |
| CNN | 0.270396 |
| MMIO / task queues | 0.250211 |
| Vector | 0.194122 |
| Shared quantizer | 0.135909 |
| Matrix | 0.110282 |
| JTAG / debug | 0.105078 |
| Top / core glue | 0.004548 |

保留层级版总计 2.587646mm²。以上包含两块SRAM，不含PAD、CTS、布线、filler和放置留白，不能据此确认2mm×2mm完整芯片能布下。

三个运行均使用相同库、约束与低effort设置；冻结输入哈希、当前功能回归和历史SIMD回归已逐项核对。

[机器报告](../reports/shared_quant_area_validation.json)。原始报告：
- [20261107-shared-quant-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area/reports/area.rpt)
- [20261107-shared-quant-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area-hier/reports/area.rpt)
- [20261107-pre-quant-simd-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-pre-quant-simd-area/reports/area.rpt)

复现汇总：

```bash
python3.12 npu/eda/tsmc180/collect_shared_quant_area.py --run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area \
  --hier-run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area-hier --baseline-run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-pre-quant-simd-area
```
