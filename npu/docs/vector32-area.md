> 本页为仲裁精简前的32位Vector面积基线；最新结果见[XBAR仲裁精简](arbitration.md)。

# 32位Vector版本综合面积

2026-11-07，TSMC180 TT、Genus19.17、low effort；16ns优化、20ns报告；两块8KB SRAM、256B RF和8/8/8队列。面积均为Cell Area，不含PAD、CTS、布线、filler或放置留白。

| 同条件比较 | VPG1宽Vector | VPG2纯32位Vector | 下降 |
|---|---:|---:|---:|
| 默认优化总面积/mm² | 2.912516 | 2.808663 | 3.57% |
| 保留层级的Vector面积/mm² | 0.309031 | 0.207111 | 32.98% |

当前默认优化版标准单元2.005776mm²，SRAM宏0.802887mm²。50MHz综合setup slack为+4.0020ns，TNS 0.0000ns，违反路径0。尚未重新布局布线。

下表为保留计算核边界的面积分布，合计2.807572mm²；它与普通优化版分别统计，不能混加：

| 模块 | mm² | 占比 |
|---|---:|---:|
| 两块SRAM宏 | 0.802887 | 28.60% |
| XBAR（RF、流FIFO、缓存与仲裁） | 0.781665 | 27.84% |
| CPU | 0.294743 | 10.50% |
| CNN计算与供数 | 0.264383 | 9.42% |
| MMIO与任务队列 | 0.243151 | 8.66% |
| Vector计算与供数 | 0.207111 | 7.38% |
| Matrix计算与供数 | 0.105984 | 3.77% |
| JTAG与Debug | 0.104878 | 3.74% |
| 顶层连接与复位等 | 0.002770 | 0.10% |

Vector内部：

- `i_core_i_vector`：0.109185mm²。
- `i_core_i_vector_stream`：0.080540mm²。
- `i_core_i_vector_light`：0.017386mm²。

功能回归仍为10张MNIST逐层整数结果一致、29,817周期/张（旧版22,219）。这次只测量综合，不宣称面积下降带来了推理加速。未重新量化模型。

原始报告：
- [20261107-vector32-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-vector32-area/reports/area.rpt)。
- [20261107-vector32-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-vector32-area-hier/reports/area.rpt)。

[完整机器报告](../reports/vector32_area_validation.json)。两份运行源码一致，冻结输入、当前RTL、工艺库哈希及其与功能回归的对应均已验证。
