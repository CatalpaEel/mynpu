# ABI 3 性能与后端验证

2026-10-29，工作区 `mynpu-torus`，软件控制的 16PE torus。旧版记录见 [v1](validation-v1.md)、[v2](validation-v2.md)。结果按功能、周期与实际物理阶段分别报告。

## 配置和验收口径

- 每 PE 四个 32bit 架构寄存器；算术仅本地写，两个源独立选择本地／四邻居及寄存器号。
- 两块共享同步单端口 8KB SRAM，CPU 代码在 bank0，唯一参数像在 bank1；每流端口 **64-word cache**，合计 512B 数据。
- CPU 原生 RV32IMC 软件、逐条 32bit MMIO 命令；没有 PE 指令 RAM、硬件微程序或层状态机。全部量化在 PE 内。
- `cycles` 从 CPU 读取启动控制后计时，包含六层、所有输出写回 SRAM、CPU argmax。JTAG 上传、启动命令自测及最后完成报告不在计时内。
- 测试台根据 CPU 三次实际 mcycle 读取事件，独立统计时钟间隔并校验固件计数；`--max-cycles 20000` 对两项强制严格 `<20000`。逐层快照的额外复制另行测试。

## 周期与正确性

**FPGA BRAM 与 ASIC SRAM 功能后端，各 64 个样本全部通过严格小于 20000 周期验收。完整推理为 19258～19262 周期，包含 CPU argmax。** 每个后端核对六层共 114816 个实际写回字节，全部符合独立整数 golden。每样本六层到 SRAM 写回均为 19129 周期，64 次独立时钟计数与固件计数完全相同。

| 功能检查 | FPGA BRAM 模型 | ASIC SRAM 功能模型 |
|---|---|---|
| 定向单元回归 | 1803 项通过 | 1803 项通过 |
| 64 样本重复推理 | 19258～19262 周期；114816 层输出字节通过 | 同左 |
| 已映射 PE + 当前 RTL 混合仿真 | 1803 项通过 | 不作为全 SoC 门级结论 |
| CPU 原生命令接口 | 连续 64 周期各接受一条，结果正确 | 同左 |
| JTAG / SBA | 真实装载、地址别名、halt/resume、无关地址并发访问 | 同左 |
| 全部逐层快照 | 当前未重跑独立快照用例 | 单样本 6 层 SRAM 快照读回通过，33708 周期 |

单元检查覆盖本地／邻居读寄存器、多精度指令、各方向环绕、shape/stride、负步长、字节使能、预取保留、目标游标、尾项排空、普通搬运 RAW/WAW、bundle 同沿旧值计算／新值提交、非法寄存器冲突无副作用、BASEPAIR 两 bank 和重复 ARM 等。

CPU 程序与只读表共 **5604B**，161 个 tile 元数据共 1932B、19 个边界模板代码槽共 1216B；这些已经包含在 5604B 中。原始参数区 4288B，另加 32B 模型派生 bias 表，权重没有复制。输入零点仍为 17；编译期 bias 折叠与原始整数运算在 INT32 回绕规则下等价。独立 golden 使用原始参数、原始 M/2^31 和原始逐项减零点逻辑。

64 个样本来自仓库既有记录，构建时逐项核对原始模型的语义哈希、记录的整数输出和 PyTorch 输出；整数 golden 与记录的 PyTorch 最终输出最大差 1 code。本次未重新运行 PyTorch，也不代表完整 MNIST 数据集准确率测试。

## 优化来源与代价

| 软件版本／配置 | 六层周期 | 含 CPU argmax |
|---|---:|---:|
| v1：每 tile 重配，串行搬运 | 167828 | 旧口径未计入 |
| v2：配置复用 + 独立预取命令 | 68686 | 68825～68828 |
| v3：原生命令复用／展开 + bundle，32 words/口，单样本 | 20104 | 20233 |
| v3：同软件，64 words/口，单样本 | 19129 | 19258 |

相对 v1，六层周期减少约 **88.6%**。收益包含 CPU 配置、发令、循环、零点折叠、并行提交／预取、缓存保留与扩容，不能全部归因于流水。

当前每次推理有 445 次描述符字段写（BASEPAIR 计两个字段），3272 条非零行 PE 运算在活动预取期间被接受，2405 个实际流 SRAM 读请求。请求接受与 ALU 同周期计数为 0：新 bundle 在响应边界提交并重启，读请求计数不涵盖响应周期。计数存在重叠，不相加构造总耗时。

## ASIC 快速综合与实际布局

当前冻结运行：`eda-runs/20261029-torus-v3-target20k`，Genus 19.17 / Innovus 21.16，TSMC180 TT，20ns 系统时钟。采用低 effort generic/map，未执行 syn_opt；复用 RTL 和库哈希一致的旧运行 PE 标准单元叶模块，周围逻辑重新综合。PE 输入网表经 1803 项混合仿真验证；本次没有全 SoC 门级回归。

| 项目 | 当前 v3，64 words/口 | v2 基线，16 words/口 |
|---|---:|---:|
| Cell Area，含两个 SRAM | **4.479290mm²** | 3.967990mm² |
| 两个 SRAM 宏 | 0.802887mm² | 0.802887mm² |
| 标准单元面积 | 3.676402mm² | 3.165103mm² |
| PE 阵列，含读选择互联 | 2.131515mm² | 2.059666mm² |
| 流单元 | 1.098621mm² | 0.657252mm² |
| 50MHz sys_clk 映射 setup slack | **+0.1349ns** | +0.0818ns |

面积单位换算依据 Cell Area，排除报告中估计连线的 Net Area；不能使用 Total Area 代替单元面积。当前综合没有 unresolved/empty module 或 undriven/multidriven pin。64-word cache 满足周期目标，但在当前寄存器式实现中扩大了流单元面积；快综合未充分优化，跨版本差值也包含映射及其他逻辑变化，不能全部当作 cache 纯增量。

2mm×2mm Die 的核心只有 **3.027321mm²**，尚须放入宏、halo、供电、间距和布线空间。当前单元面积本身已超过整个 Die，**不能放入 2mm×2mm**。实际 floorplan/IO 已完成，`checkFPlan` core utilization 为 **147.090904%**。供电阶段已完成。实际 placement 因 **可放置区域利用率 180.2%** 被 `IMPSP-190` 拒绝：工具报告标准单元需求 3637503µm²，可分配区域仅 2018759µm²。floorplan core utilization 与 placer utilization 的扣除项不同，应分别引用。CTS／route 未运行，保留失败日志和供电 checkpoint。

映射最差路径位于 CPU ALU／译码到操作数寄存器，报告数据路径约 19.330ns、时钟不确定度 0.520ns。这是 global interconnect 的布线前估计。没有 CTS／详细布线后的时序、功耗或 signoff 结论；正映射 slack 不能用于宣称芯片已达成 50MHz。

## 复现与文件

```bash
python3 tools/build_torus.py --out build/torus/final-full --vectors 64 --corpus tests/torus/mnist_vectors_full.json
python3 tools/run_torus.py --memory fpga --suite unit --cache-words 64 --tag final64
python3 tools/run_torus.py --memory asic --suite unit --cache-words 64 --tag final64
python3 tools/run_torus.py --memory fpga --suite soc --assets build/torus/final-full --cache-words 64 --max-cycles 20000 --tag final64
python3 tools/run_torus.py --memory asic --suite soc --assets build/torus/final-full --cache-words 64 --max-cycles 20000 --tag final64
```

- [完整资产 manifest](../../build/torus/final-full/manifest.json)、[CPU ELF](../../build/torus/final-full/cpu.elf)、[CPU hex](../../build/torus/final-full/cpu.hex)、[模型像](../../build/torus/final-full/model.hex)、[全部逐层 golden](../../build/torus/final-full/golden.hex)。
- [FPGA 单元](../../build/torus/unit-fpga-final64/result.json)、[ASIC 单元](../../build/torus/unit-asic-final64/result.json)、[映射 PE 混合仿真](../../build/torus/unit-fpga-mapped64/result.json)。
- [FPGA 64 样本](../../build/torus/soc-fpga-final64/result.json)、[ASIC 64 样本](../../build/torus/soc-asic-final64/result.json)、[ASIC 逐层快照](../../build/torus/soc-asic-tapall-final-snapshot/result.json)、[32-word 对照](../../build/torus/soc-fpga-final-cache32/result.json)。
- [当前综合面积](../../../eda-runs/20261029-torus-v3-target20k/mynpu/chip_synth/area.rpt)、[映射时序](../../../eda-runs/20261029-torus-v3-target20k/mynpu/chip_synth/timing.rpt)、[QoR](../../../eda-runs/20261029-torus-v3-target20k/mynpu/chip_synth/qor.rpt)、[冻结输入清单](../../../eda-runs/20261029-torus-v3-target20k/inputs/source_manifest.json)。
- [floorplan 几何](../../../eda-runs/20261029-torus-v3-target20k/mynpu/pnr/reports/floorplan_geometry.rpt)、[容量检查](../../../eda-runs/20261029-torus-v3-target20k/mynpu/pnr/reports/floorplan_check.rpt)、[放置失败日志](../../../eda-runs/20261029-torus-v3-target20k/mynpu/pnr/03_launcher.log)、[后端汇总](../../../eda-runs/20261029-torus-v3-target20k/validation/backend_summary.json)。

全部最终回归的 `changed_during_run` 均为空；当前物理快照的 98 个 RTL 输入与实测版本哈希一致。[汇总 JSON](../../build/torus/final-validation.json) 同时记录周期达标、面积未达标和布线后 50MHz 尚未验证三个独立状态。

`result.json` 记录通过状态、实测输出、源码和运行资产 SHA256、运行期间变化列表。`build/` 由 Git 忽略，可重新构建；后端目录保留工具日志和数据库。实现说明见 [README](README.md)、[流水调度](overlap.md)、[EDA 与 GUI](../../eda/tsmc180/README.md)。修改未提交或推送。
