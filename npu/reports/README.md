# 报告索引与版本审计

2026-11-19。报告是冻结证据，文件名不带日期也不表示当前版本；不修改原报告里的历史数值或当时结论。

## 当前采用的入口

| 报告 | 适用范围 |
| --- | --- |
| [asic_main53655b5_20261118_validation.json](asic_main53655b5_20261118_validation.json) | 2026-11-18当前ASIC完整复跑与源码哈希；严格LVS/ERC残项保留。 |
| [main53655b5_20261118_r1_fullchip_validation.json](main53655b5_20261118_r1_fullchip_validation.json) | 当前最终PNR：核心2.634323mm²、50MHz +0.457/+0.020ns；核心物理检查通过。 |
| [lab5_main53655b5_20261118_r1_validation.json](lab5_main53655b5_20261118_r1_validation.json) | 当前最终Lab5：课程排除外DRC/天线/WB为0，教学LVS CORRECT，严格PR/ERC未关闭。 |
| [ego1_merge_validation_20261114.json](ego1_merge_validation_20261114.json) | 2026-11-14合并时冻结集成：FPGA/ASIC各20帧、CPU RF 40000检查、Vivado 2025.2 RTL展开；未做新PPA/板测。 |
| [jtag-only-validation.json](jtag-only-validation.json) | 合并前JTAG-only冻结功能验证：无GPIO版，含不停机CPU/NPU/SBA竞争、宏模型及EGo1壳层；未重跑PPA/实体板。 |
| [rf1r1w-validation.json](rf1r1w-validation.json) | JTAG-only改动前冻结证据：RF功能、21,008周期MNIST及综合2.569286mm²；内部“未跑PNR”是当时快照，后续见r3。 |
| [rf1r1w_die1950_fullchip_validation.json](rf1r1w_die1950_fullchip_validation.json) | JTAG-only改动前冻结证据：最终r3布局布线；核心非filler 2.632349mm²、50MHz +0.468/+0.018ns。 |
| [lab5_rf1r1w_die1950_validation.json](lab5_rf1r1w_die1950_validation.json) | JTAG-only改动前冻结证据：最终r3课程检查；严格PR/ERC残项保留，非正式投片全部通过。 |
| [ego1_preboard_validation.json](ego1_preboard_validation.json) | JTAG-only改动前冻结证据：EGo1功能仿真38项；尚无本版Vivado综合/实现/实体板结果。 |
| [backend_source_audit.json](backend_source_audit.json) | JTAG-only改动前冻结证据：70个ASIC输入、24个项目RTL与默认配置核对。 |

## 旧版FPGA归档

[2026-11-14旧版实板报告](ego1_board_validation_20261114.json)与[构建试验](ego1_validation_preparation.json)适用于afb74fd/03e2870。归档10MHz镜像在halt/resume流程下通过2021次推理，不代表当前合并后设计通过实体板测；见[固定版本](../fpga/ego1/versions/ego1-10mhz-20261114/README.md)。

## 版本判读

当前不含GPIO、Host；最新ASIC完整复跑见2026-11-18的三个当前报告，含70份源码哈希与最终产物校验。旧r3与EGo1合并验证保留为历史证据。
原始当前报告中的对照字段与阶段追踪作为证据保留；首页指标只使用当前最终结果。
审计详细记录每份JSON的已记录源哈希比对，以及最终PNR/Lab5产物完整性。部分哈希一致不等于整份报告对应当前设计；缺少证据时不推断通过。
输入版本一致也不等于检查全部通过：最终Lab5仍保留ERC及严格PR限制。

完整机器清单：[report_inventory.json](report_inventory.json)。重新审计：`python3.12 npu/scripts/audit_reports.py`。

## 全量清单

| 文件 | 定位 | 源哈希观察：一致/不同/缺失 |
| --- | --- | --- |
| [asic_main53655b5_20261118/13_final_antenna.rpt](asic_main53655b5_20261118/13_final_antenna.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/13_final_drc.rpt](asic_main53655b5_20261118/13_final_drc.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/13_final_pg.rpt](asic_main53655b5_20261118/13_final_pg.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/13_final_place.rpt](asic_main53655b5_20261118/13_final_place.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/13_final_signal.rpt](asic_main53655b5_20261118/13_final_signal.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/13_implemented_footprint.rpt](asic_main53655b5_20261118/13_implemented_footprint.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/antenna_summary.rpt](asic_main53655b5_20261118/antenna_summary.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/drc_post_summary.rpt](asic_main53655b5_20261118/drc_post_summary.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/export_audit.json](asic_main53655b5_20261118/export_audit.json) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/extents_diagnostic.txt](asic_main53655b5_20261118/extents_diagnostic.txt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/final_hold.rpt](asic_main53655b5_20261118/final_hold.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/final_setup.rpt](asic_main53655b5_20261118/final_setup.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/lvs_erc.summary](asic_main53655b5_20261118/lvs_erc.summary) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/lvs_report.rpt](asic_main53655b5_20261118/lvs_report.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/lvs_strict_report.rpt](asic_main53655b5_20261118/lvs_strict_report.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/postCTS_hold.rpt](asic_main53655b5_20261118/postCTS_hold.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/postCTS_holdFix_hold_check.rpt](asic_main53655b5_20261118/postCTS_holdFix_hold_check.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/postRoute_hold.rpt](asic_main53655b5_20261118/postRoute_hold.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/sealring_poc.txt](asic_main53655b5_20261118/sealring_poc.txt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/synth_area.rpt](asic_main53655b5_20261118/synth_area.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/synth_qor.rpt](asic_main53655b5_20261118/synth_qor.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/synth_timing.rpt](asic_main53655b5_20261118/synth_timing.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/synth_unresolved.rpt](asic_main53655b5_20261118/synth_unresolved.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118/wb_summary.rpt](asic_main53655b5_20261118/wb_summary.rpt) | 本轮报告摘录 | 无可直接比对的源哈希 |
| [asic_main53655b5_20261118_validation.json](asic_main53655b5_20261118_validation.json) | 当前范围 | 70/0/0 |
| [backend_source_audit.json](backend_source_audit.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115.json](ego1_bitstream_20261115.json) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/cdc.rpt](ego1_bitstream_20261115/cdc.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/check_timing.rpt](ego1_bitstream_20261115/check_timing.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/drc.rpt](ego1_bitstream_20261115/drc.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/implementation_pass.txt](ego1_bitstream_20261115/implementation_pass.txt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/methodology.rpt](ego1_bitstream_20261115/methodology.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/resume_bitstream.tcl](ego1_bitstream_20261115/resume_bitstream.tcl) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/route_status.rpt](ego1_bitstream_20261115/route_status.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/timing_routed.rpt](ego1_bitstream_20261115/timing_routed.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_bitstream_20261115/utilization_routed.rpt](ego1_bitstream_20261115/utilization_routed.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_board_validation_20261114.json](ego1_board_validation_20261114.json) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_lut_optimization_20261114.json](ego1_lut_optimization_20261114.json) | 历史快照 | 3/0/0 |
| [ego1_lut_optimization_20261114/drc_opt.rpt](ego1_lut_optimization_20261114/drc_opt.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_lut_optimization_20261114/utilization_opt_flat.rpt](ego1_lut_optimization_20261114/utilization_opt_flat.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_lut_optimization_20261114/utilization_opt_hier.rpt](ego1_lut_optimization_20261114/utilization_opt_hier.rpt) | 历史快照 | 无可直接比对的源哈希 |
| [ego1_merge_validation_20261114.json](ego1_merge_validation_20261114.json) | 历史快照 | 81/5/0 |
| [ego1_preboard_validation.json](ego1_preboard_validation.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [ego1_validation_preparation.json](ego1_validation_preparation.json) | 历史快照 | 0/24/0 |
| [jtag-only-validation.json](jtag-only-validation.json) | EGo1合并前冻结证据 | 75/7/0 |
| [lab5_main53655b5_20261118_r1_validation.json](lab5_main53655b5_20261118_r1_validation.json) | 当前范围 | 无可直接比对的源哈希 |
| [lab5_rf1r1w_die1950_validation.json](lab5_rf1r1w_die1950_validation.json) | JTAG-only改动前冻结证据 | 无可直接比对的源哈希 |
| [main53655b5_20261118_r1_fullchip_validation.json](main53655b5_20261118_r1_fullchip_validation.json) | 当前范围 | 2/0/0 |
| [rf1r1w-validation.json](rf1r1w-validation.json) | JTAG-only改动前冻结证据 | 1/0/0 |
| [rf1r1w_die1950_fullchip_validation.json](rf1r1w_die1950_fullchip_validation.json) | JTAG-only改动前冻结证据 | 2/0/0 |
