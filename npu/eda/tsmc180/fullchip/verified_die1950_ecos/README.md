# 已验证的1950µm物理ECO脚本

这些文件逐字节复制自2026-11-10 RF 1R1W后端实际成功执行的Tcl快照。源路径和SHA256见provenance.json，结果见[完整报告](../../../../docs/rf1r1w-die1950-signoff.md)。不包含PDK、工艺规则、GDS或大型运行数据库。

脚本针对本轮冻结网表及1950µm几何，不是任意设计可直接运行的通用修复。端点名称、CPU网络名、PG坐标与原始检查点必须匹配；更换网表后应重新定位实际违规。

顺序与入口检查点：

1. finish_pg_pad_access.tcl：从13_finished.enc.dat修复PG重复过孔、底边单元与外部PAD接入，保存13_eco_fixed。
2. fix_io_m2_spacing.tcl：从13_eco_fixed.enc.dat修复原生IO宽M2间距，保存13_calibre_fixed。
3. fix_bond_pad_spacing.tcl：从13_calibre_fixed.enc.dat增加实际Bond金属的2.5µm信号routing keepout，保存13_wb_fixed。
4. export_final.tcl：从13_wb_fixed.enc.dat导出最终PNR交付文件。

通过run_fullchip.py的--stage-script传入。运行器会把脚本冻结到运行目录scripts/，脚本再由该位置确定run_root。运行目录还需完整参考流程、输入、库、检查点；执行命令完成后必须检查真实DRC、连接与时序报告，再对最终GDS执行完整Calibre检查。不能只凭脚本退出码判断通过。

```sh
python3.12 npu/eda/tsmc180/run_fullchip.py --run <运行目录> --stages 06 --stage-script npu/eda/tsmc180/fullchip/verified_die1950_ecos/fix_bond_pad_spacing.tcl --tag NEW_WB_ECO
```
