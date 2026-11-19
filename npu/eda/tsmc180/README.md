# TSMC180 ASIC 流程

> 当前main不含GPIO、外部Host。2026-11-18已重跑完整后端：综合2.569738mm²、PNR核心2.634323mm²、50MHz +0.457/+0.020ns；详见[本轮报告](../../docs/asic-main53655b5-signoff-20261118.md)。严格LVS/ERC残项保留。下文2026-11-10 r3作为历史基线。

## 文件入口

| 想做什么 | 入口 |
| --- | --- |
| 自己从GUI跑一轮 | [完整GUI教程](../../docs/backend-gui-lab.md) |
| 创建独立工作区 | [gui_lab/](gui_lab/README.md)，不启动EDA计算 |
| 查看本次ASIC复跑过程 | [2026-11-18执行记录](../../docs/asic-main53655b5-signoff-20261118.md) |
| 查看最新数字与原始报告 | [报告索引](../../reports/README.md) |
| 维护主PNR流程 | `fullchip/pnr_*.tcl`及`run_fullchip.py` |
| 查看本次已验证ECO | [verified_main53655b5_20261118/](verified_main53655b5_20261118/README.md) |
| 学习旧版每组命令与GUI变化 | [专题教程](../../docs/backend-tcl-gui-tutorial.md)，其数值为旧r3 |

综合、网表、OA/Innovus数据库与PDK都在独立运行目录，不放到脚本目录。`gui_lab/workspace_tools`是工作区模板，实际运行器在生成的`backend_lab/`中使用。

## 历史r3基线

完整物理基线为 **2026-11-10 RF 1R1W、1950µm、最终r3**：
[最终后端报告](../../docs/rf1r1w-die1950-signoff.md)、[布局布线机器报告](../../reports/rf1r1w_die1950_fullchip_validation.json)、[Lab 5机器报告](../../reports/lab5_rf1r1w_die1950_validation.json)。

2026-11-11核对冻结`core_source_manifest.source_sha256`：70个输入文件与工作区一致，其中包含全部24个项目RTL。
清单中的`git_commit=549b352`是冻结时的Git基线，不表示当时工作区没有修改；RF 1R1W以源码哈希为证。
核对明细见[源码审计](../../reports/backend_source_audit.json)。后续README整理和EGo1板级文件不改变ASIC核心。

## 当前测量与边界

| 项目 | 最终r3 |
| --- | --- |
| 综合cell面积，含2块SRAM，不含PAD/CTS/布线 | 2.569286 mm² |
| PNR核心非filler面积，含SRAM、不含外围IO | 2.632349 mm² |
| Die / Seal Ring外框 | 1950×1950 / 1980×1980 µm |
| 50MHz布线后setup / hold WNS | +0.468 / +0.018 ns |
| 布线后9信号PAD JTAG/MNIST | 34项检查通过，无SDF |

课程规则排除后DRC为0，教学PR容差LVS为CORRECT，天线/WB为0；严格PR参数偏差和ERC残项仍待评审。
未完成Dummy后PEX/STA、多角、IR/EM，不能视为正式投片签核全部通过。

## 服务器上的实际结果

以下均位于仓库同级`../eda-runs/`，不提交大型运行数据库或PDK：

| 目录 | 内容 |
| --- | --- |
| `20261110-rf1r1w/` | 核心综合、源文件与库manifest、网表和报告 |
| `20261110-rf1r1w-die1950-fullchip-r3/` | 最终全芯片PNR、检查点、导出、物理ECO |
| `20261110-rf1r1w-lab5-die1950-r3/` | 最终GDS后续课程检查 |

最终阶段和产物哈希以机器报告为准。首次运行、r2及11月9日1RW报告仍可作为历史证据，不能替代r3。

## 新建综合运行

从仓库根目录执行，使用新的独立输出目录。以下参数对应当前核心综合策略：

```sh
python3.12 npu/eda/tsmc180/prepare_run.py \
  --out ../eda-runs/NEW_CORE --effort high --clock-gating \
  --preserve-unit-boundaries --synth-period 18 --report-period 20
(cd ../eda-runs/NEW_CORE && genus -no_gui -batch -files synth.tcl > launcher.log 2>&1)
python3.12 npu/scripts/run_gate.py --run ../eda-runs/NEW_CORE --suite latency --tag NEW_LATENCY
```

RF及队列默认读取`npu/build_config.json`：RF32 words/逻辑半区，Matrix/Vector/CNN队列4/4/4，流FIFO8 words。
需要服务器TSMC180标准单元库与RA1SHD_2048x32M8宏文件；具体路径和选项使用脚本`--help`查询。
修改容量需同步生成相同配置的固件。当前记录的MNIST为21,008周期，不应继续使用旧“小于20k”的验收描述。

## 全芯片与物理修复

`prepare_chip.py`准备9信号PAD封装，`run_fullchip.py`执行分阶段PNR，`collect_fullchip.py`收集结果。
新运行必须从自己的已验证核心网表开始，不应继续引用旧11月4日核心：

```sh
python3.12 npu/eda/tsmc180/prepare_chip.py --core ../eda-runs/NEW_CORE --out ../eda-runs/NEW_CHIP
(cd ../eda-runs/NEW_CHIP && genus -no_gui -batch -files scripts/synth_chip.tcl > mynpu/chip_synth/launcher.log 2>&1)
python3.12 npu/scripts/run_chip_gate.py --run ../eda-runs/NEW_CHIP --tag NEW_CHIP_GATE
```

这些命令仅准备/综合封装，不自动复现最终1950µm几何和全部物理ECO。
1950µm floorplan、SRAM/PAD摆放及最终修复以实际r3冻结脚本和manifest为准，细节见最终报告。
通用模板用于新运行；固定网络名与坐标的已验证修复见[verified_die1950_ecos](fullchip/verified_die1950_ecos/README.md)。
更换网表后须重新定位违规，不能直接套用旧ECO或把工具退出码当作收敛证据。

Lab 5后续检查必须使用最终导出的GDS/网表和相同原库，按报告核查V2LVS、Seal Ring、Dummy、DRC、LVS/ERC、天线与Wire Bond。
完整课程流程命令及限制见[最终报告](../../docs/rf1r1w-die1950-signoff.md)。

## 运行目录与Git

Genus/Innovus在进程当前目录生成`*.cmd*`、轮转日志和`fv/`，因此应先进入独立运行目录。
`run_fullchip.py`本身设置运行cwd；只重定向stdout或`-files`路径不能避免根目录污染。
生成日志、网表、检查点及大型物理产物不入Git。维护脚本、精选报告及文档截图保留。
旧生成物本地备份为`../eda-runs/20261110-repository-cleanup/`，含SHA256清单。
