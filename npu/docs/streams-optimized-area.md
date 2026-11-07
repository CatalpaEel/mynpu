# 三种Stream精简后的面积与时序

优化RTL提交 `9b55588`，与优化前4×4 Matrix版本比较。

| 项目 | 优化前 mm² | 优化后 mm² |
|---|---:|---:|
| 默认综合总面积 | 2.976653 | 2.846849 |
| 标准单元 | 2.173766 | 2.043962 |
| 两块SRAM | 0.802887 | 0.802887 |

总面积减少 **0.129804mm²（4.36%）**。相对3mm²单元面积预算余量为0.153151mm²。

| Stream分项（保留层级） | 优化前 mm² | 优化后 mm² | 减少 |
|---|---:|---:|---:|
| Matrix Stream | 0.209350 | 0.120936 | 42.23% |
| CNN Stream引擎 | 0.162219 | 0.146194 | 9.88% |
| CNN控制/队列 | 0.047967 | 0.047967 | 0.00% |
| CNN Stream合计 | 0.210186 | 0.194161 | 7.62% |
| Vector Stream | 0.076926 | 0.067072 | 12.81% |

保留层级版总面积为2.846689mm²，分项不与默认版总数混加。CNN Stream合计已包含引擎与控制，不能再重复相加。

50MHz综合setup slack为 **+4.0020ns**，TNS 0.0000ns，违反路径0。

以上包含真实两块SRAM宏，不含PAD、CTS、布线、filler及放置留白；未重跑PNR或测量功耗。冻结源码、工艺库和功能回归哈希均已核对。

## 功能与周期

21组验证通过，其中15组重新运行、6组未变模块按源码哈希复用。默认VPG2为29,173周期/张，共享量化为27,432周期/张；旧固件为30,710周期。三者均与优化前一致。两条新软件路径各10张图、60个中间层张量、17,940字节逐字节匹配golden。

[功能说明](streams-optimized.md)，[机器面积报告](../reports/streams_optimized_area_validation.json)。原始报告：

- [20261107-streams-opt-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-streams-opt-area/reports/area.rpt)
- [20261107-streams-opt-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-streams-opt-area-hier/reports/area.rpt)
- [20261107-outer4-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area/reports/area.rpt)
- [20261107-outer4-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area-hier/reports/area.rpt)
- [当前时序报告](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-streams-opt-area/reports/timing.rpt)
