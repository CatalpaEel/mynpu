# 2026-11-18当前main后端ECO快照

这些Tcl来自main53655b5本轮成功执行的1950µm、9信号PAD布局布线，不是任意网表的通用修复脚本。源路径与SHA256见provenance.json。

顺序：cleanup_external_pad_routes从13_finished恢复并保存13_padclean；fix_current_bond_spacing从13_padclean恢复、按37个原生Bond金属边界添加keepout、检查只重布非时钟网，保存13_wb_fixed；export_wb_final导出最终文件。可通过run_fullchip.py的--stage-script执行单阶段，但必须先分析新设计实际违规、确认拓扑与几何匹配，再重新验证原生检查、时序、门级功能及完整Calibre。

本轮只重布1条CPU非时钟网络，没有使用旧版写死的PG重叠/M2网络ECO。结果与签核限制见[本轮报告](../../../docs/asic-main53655b5-signoff-20261118.md)。
