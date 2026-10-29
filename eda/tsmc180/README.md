# mynpu torus 的 TSMC180 综合与后端

当前实验工作区为 `/home/s2400012841/chip-fullstack-2026/mynpu-torus`。此目录保存公开的运行脚本、约束和 GUI 入口；独立运行快照与报告保存在父目录 `eda-runs/`。PDK 为 `/home/almalinux/tsmc180`，SRAM 为服务器课程库 RA1SHD_2048x32M8，不复制或发布专有模型／库。

当前配置为 16 个四寄存器 PE、torus 邻居读、两个共享 8KB 单端口 SRAM、每流端口 32-word cache，9 个信号 PAD，2mm×2mm Die，50MHz 系统时钟，单 TT 视图。测试芯片采用课程 Lab4 的 IO、floorplan、供电、放置、CTS 和布线流程。功能回归与物理时序验证分别记录。

## 建立冻结运行

```bash
cd /home/s2400012841/chip-fullstack-2026/mynpu-torus
export EDA_RUN_ROOT=/home/s2400012841/chip-fullstack-2026/eda-runs/$(date -u +%Y%m%d-%H%M%S)-torus
/usr/bin/python3.12 eda/tsmc180/prepare_run.py --out "$EDA_RUN_ROOT" --topology torus --cache-words 32
FLOW_SYNTH_EFFORT=medium bash eda/tsmc180/run_stage.sh "$EDA_RUN_ROOT" grid
```

`prepare_run.py` 冻结 RTL、脚本、宏路径与所有相关库的 SHA256。默认完整执行 generic/map/opt；本轮使用 `FLOW_SYNTH_EFFORT=medium`。`FLOW_FAST_AREA=1` 使用低 effort 的 `syn_generic`、`syn_map`，跳过 `syn_opt` 与综合数据库导出；保留已映射网表、面积、约束、时序报告和 `GRID_FAST_AREA_PASS` 标记。物理阶段从网表导入，因此仍能运行 floorplan／placement。未优化且未布线的 setup slack 只能作为快速估计。

已有完成的全芯片运行、PE RTL 和库哈希均一致时，可在 prepare 命令增加 `--mapped-torus-run BASELINE_RUN`。工具只提取未修改的 PE 标准单元叶模块，其余 RTL 重新综合；提取器拒绝缺少完成标记、库或 RTL 不匹配及非标准单元依赖。当前映射 PE 与 RTL 的混合网表已通过 4973 项单元测试，但不等同于全 SoC 的门级回归。

当前还支持先综合独立 PE，再复用经过验证的门级叶模块。独立 PE 的时序环境与整芯片不同，其面积不能乘 16 后代替整芯片结果；完整 grid 阶段会重新处理阵列互联、负载和时序。

```bash
export EDA_PE_ROOT=/home/s2400012841/chip-fullstack-2026/eda-runs/$(date -u +%Y%m%d-%H%M%S)-torus-pe
/usr/bin/python3.12 eda/tsmc180/prepare_run.py --out "$EDA_PE_ROOT" --topology torus --cache-words 32
bash eda/tsmc180/run_stage.sh "$EDA_PE_ROOT" pe
# 完成并检查 PE 报告后，在新运行中导入该叶模块。
/usr/bin/python3.12 eda/tsmc180/prepare_run.py --out "$EDA_RUN_ROOT" --topology torus --cache-words 32 --mapped-torus-run "$EDA_PE_ROOT"
FLOW_SYNTH_EFFORT=medium bash eda/tsmc180/run_stage.sh "$EDA_RUN_ROOT" grid
```

这段是替代前面完整 RTL 构建的方式，`EDA_RUN_ROOT` 须选择尚不存在的新目录。独立 PE 运行必须包含完成标记和未修改的脚本／源文件／库哈希，提取器才会接受。

综合报告位于 `$EDA_RUN_ROOT/mynpu/chip_synth/`：

- `area.rpt`：看 **Cell Area**，其中包括两个 SRAM。不要使用含估算连线面积的 Total Area 作为单元占用。
- `timing.rpt`、`qor.rpt`：20ns 时钟下的映射时序估计。
- `check_design.rpt`、`unresolved.rpt`、`launcher.log`：检查黑盒、错误和完成标记。本轮完整流程的冻结脚本未导出最终 unresolved 单独报告，以最终 check_design 的零 unresolved/empty/undriven-leaf 计数核对；新脚本已补齐单独报告。
- `mynpu_asic_top.postsyn.v`、SDC：物理流程输入。

## 实际检查布局容量

各阶段成功且报告合理后再执行下一步；所有命令拒绝覆盖已有日志。

```bash
bash eda/tsmc180/run_stage.sh "$EDA_RUN_ROOT" 01  # IO / floorplan
bash eda/tsmc180/run_stage.sh "$EDA_RUN_ROOT" 02  # powerplan
bash eda/tsmc180/run_stage.sh "$EDA_RUN_ROOT" 03  # placement
```

报告在 `mynpu/pnr/` 和其 reports 子目录。2mm×2mm 的 4mm² 包含 PAD，核心可放置面积约 3.027mm²；还需扣除宏、halo、供电与布局限制。单元面积接近 4mm² 已经不能由“芯片总面积是 4mm²”推断可以放下。placer 因利用率超过 100% 失败时，应保留日志和 floorplan 数据库，先减面积或另行修改尺寸；不能据此宣布 CTS／布线／50MHz 通过。

放置通过后依次运行 `04`、必要时 `04b`、`05`、`06`、必要时 `06b`、`07`、`audit`。`run_flow.py` 可自动驱动修复，但必须先检查面积容量和前序报告。只有最终提取 RC 后的 setup/hold 报告能用于说明布线后的时序；PDK signoff 和宏内部 timing-check 验收不在本次范围。

## GUI 查看

在服务器图形桌面终端执行：

```bash
bash eda/tsmc180/launch_gui.sh "$EDA_RUN_ROOT" init
bash eda/tsmc180/launch_gui.sh "$EDA_RUN_ROOT" 03_io_floorplan
bash eda/tsmc180/launch_gui.sh "$EDA_RUN_ROOT" 06_powerplan
```

`init` 导入网表与库；其他名字恢复已有数据库。恢复后不要再次初始化或重复创建 IO／供电对象。打开 Design Browser 检查两个 SRAM 和 PE 实例；在 Visibility 中显示 core／die、macro、placement blockage 和 PG；选择对象查看属性，并结合日志中的 `checkFPlan` 利用率判断容量。

后续成功阶段可恢复 `08_post_tie`、`10_post_cts`、`11_pre_route`、`12_routed`、`13_finished`、`14_exported`。只打开实际存在且通过检查的 checkpoint。当前测量与失败范围详见 [torus 验证记录](../../docs/torus/validation.md)；旧 4-lane 或旧 mesh 的版图不能代表本分支。

综合和实际放置结束后，可生成可审阅的面积／功能汇总：

```bash
python3 tools/collect_torus_area.py --run "$EDA_RUN_ROOT" --baseline /home/s2400012841/chip-fullstack-2026/eda-runs/20261029-torus-v3-target20k --functional build/torus/area-v4-functional.json --out build/torus/area-v4-validation.json
```

汇总器要求综合完成标记、冻结 RTL 完整性、库文件哈希、零 unresolved/empty/undriven-leaf/multidriven-leaf 检查，并分别记录当前源文件匹配情况及真实放置阶段结果。它不会将映射 slack 当成布线后频率。

2026-10-29 当前运行 `../eda-runs/20261029-torus-area-v4` 完成 medium 全综合，Cell Area 3.320404mm²，50MHz 映射 setup slack +0.0203ns。实际 IO／供电完成，placement 因利用率 122.3% 被拒绝，未运行 CTS／route。可通过 GUI 恢复 `06_powerplan` 查看当前宏和供电布局。
