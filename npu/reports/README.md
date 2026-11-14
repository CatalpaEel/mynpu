# 报告索引与版本审计

2026-11-14。报告是冻结证据，文件名不带日期也不表示当前版本；不修改原报告里的历史数值或当时结论。

## 当前采用的入口

| 报告 | 适用范围 |
| --- | --- |
| [ego1_merge_validation_20261114.json](ego1_merge_validation_20261114.json) | 当前本地集成：FPGA/ASIC各20帧、CPU RF 40000检查、Vivado 2025.2 RTL展开；未做新PPA/板测。 |
| [jtag-only-validation.json](jtag-only-validation.json) | 合并前JTAG-only冻结功能验证：无GPIO版，含不停机CPU/NPU/SBA竞争、宏模型及EGo1壳层；未重跑PPA/实体板。 |
| [rf1r1w-validation.json](rf1r1w-validation.json) | JTAG-only改动前冻结证据：RF功能、21,008周期MNIST及综合2.569286mm²；内部“未跑PNR”是当时快照，后续见r3。 |
| [rf1r1w_die1950_fullchip_validation.json](rf1r1w_die1950_fullchip_validation.json) | JTAG-only改动前冻结证据：最终r3布局布线；核心非filler 2.632349mm²、50MHz +0.468/+0.018ns。 |
| [lab5_rf1r1w_die1950_validation.json](lab5_rf1r1w_die1950_validation.json) | JTAG-only改动前冻结证据：最终r3课程检查；严格PR/ERC残项保留，非正式投片全部通过。 |
| [ego1_preboard_validation.json](ego1_preboard_validation.json) | JTAG-only改动前冻结证据：EGo1功能仿真38项；尚无本版Vivado综合/实现/实体板结果。 |
| [backend_source_audit.json](backend_source_audit.json) | JTAG-only改动前冻结证据：70个ASIC输入、24个项目RTL与默认配置核对。 |

## 旧版FPGA归档

[2026-11-14旧版实板报告](ego1_board_validation_20261114.json)与[构建试验](ego1_validation_preparation.json)适用于afb74fd/03e2870。归档10MHz镜像在halt/resume流程下通过2021次推理，不代表当前合并后设计通过实体板测；见[固定版本](../fpga/ego1/versions/ego1-10mhz-20261114/README.md)。

## 版本判读

当前main不含GPIO，Host接口已删除；当前本地集成结果见ego1_merge_validation_20261114；合并前功能结果见jtag-only-validation。旧r3物理检查仅为冻结基线，不代表本次改动后的PPA或签核。
原始当前报告中的对照字段与阶段追踪作为证据保留；首页指标只使用当前最终结果。
审计详细记录每份JSON的已记录源哈希比对，以及最终PNR/Lab5产物完整性。部分哈希一致不等于整份报告对应当前设计；缺少证据时不推断通过。
输入版本一致也不等于检查全部通过：最终Lab5仍保留ERC及严格PR限制。

完整机器清单：[report_inventory.json](report_inventory.json)。重新审计：`python3.12 npu/scripts/audit_reports.py`。

## 全量清单

| 文件 | 定位 | 源哈希观察：一致/不同/缺失 |
| --- | --- | --- |
| [backend_source_audit.json](backend_source_audit.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [ego1_board_validation_20261114.json](ego1_board_validation_20261114.json) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_merge_validation_20261114.json](ego1_merge_validation_20261114.json) | 当前范围 | 86/0/0 |
| [ego1_preboard_validation.json](ego1_preboard_validation.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [ego1_validation_preparation.json](ego1_validation_preparation.json) | 历史快照 | 0/24/0 |
| [jtag-only-validation.json](jtag-only-validation.json) | EGo1合并前冻结证据 | 80/2/0 |
| [lab5_rf1r1w_die1950_validation.json](lab5_rf1r1w_die1950_validation.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [rf1r1w-validation.json](rf1r1w-validation.json) | JTAG-only改动前冻结证据 | 1/0/0 |
| [rf1r1w_die1950_fullchip_validation.json](rf1r1w_die1950_fullchip_validation.json) | JTAG-only改动前冻结证据 | 2/0/0 |
