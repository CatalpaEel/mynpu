# 2026-11-18最终ASIC报告摘录

本目录保存原始报告副本；不要重新格式化或覆盖它们。当前结果索引为[汇总](../asic_main53655b5_20261118_validation.json)、[PNR](../main53655b5_20261118_r1_fullchip_validation.json)和[Lab5](../lab5_main53655b5_20261118_r1_validation.json)。

- `synth_*`：核心综合面积、时序、QOR与未解析检查。
- `postCTS_*`、`postRoute_hold.rpt`：修复前后阶段追踪，不能当作最终结果。
- `final_setup.rpt`、`final_hold.rpt`、`13_final_*`：最终时序、DRC、连接与放置。
- `drc_post_*`、`antenna_*`、`wb_*`：最终Calibre检查。
- `lvs_report.rpt`与`lvs_strict_report.rpt`：教学容差与严格LVS分开保存。
- `lvs_erc.summary`：未关闭的ERC结果。
- `sealring_poc.txt`、`extents_diagnostic.txt`：环与标签边界诊断。

本目录不是可运行工程。当前Tcl入口见[脚本索引](../../eda/tsmc180/README.md)，大型原始运行、数据库与GDS路径见[完整报告](../../docs/asic-main53655b5-signoff-20261118.md)。
