# 后端面积优化与DRC修复简报

范围：GPIO加入前，RF 1R1W、1950µm die、最终r3。面积实验来自不同历史阶段，不能把每项节省直接累加。本文整理既有测量，没有重新运行EDA。

## 1. 设计如何砍面积

原则是保留Matrix 4×4、CNN 3×3 DOT9和Vector计算能力，优先减少供数、控制和存储开销，不采用数据锁存器方案。

| 手段 | 实测综合面积mm² | 代价/边界 |
| --- | ---: | --- |
| 整理Stream供数与控制逻辑 | 2.976653→2.846849，下降4.36% | 保留Matrix阵列；减少外围冗余而非削减MAC |
| 三个任务队列8→4 | 2.637060→2.569744，下降2.55% | payload存储2712→1356bit；MNIST 20728→21008周期，增加1.35% |
| 门控、high effort和周期搜索 | 历史阶段2.846849→2.515488，下降11.64% | 包含多项变化，不能全部算作门控或effort收益 |

Stream层次历史测量中，Matrix Stream由0.209350降到0.120936mm²，CNN engine由0.162219降到0.146194mm²，Vector Stream由0.076926降到0.067072mm²。这些属于对应历史综合，不是最终r3模块占比。

**最终保留配置：** 256B RF、8 bank各1R1W、任务队列4/4/4、四条stream FIFO各8 words。RF改1R1W的目的是并发，并非压面积：孤立RF面积略增，整芯片映射后近似持平。

最终综合含SRAM为**2.569286mm²**；PNR核心非filler含SRAM为**2.632349mm²**。后者包含CTS、hold修复及物理支持开销，不含外围IO和core filler，不能当作整个die面积。

## 2. Genus high effort效果：之前确实有显式low

查到历史快速综合脚本明确设置了三个`low`，不是仅仅“忘了开high”或依赖未知默认值。对同一历史RTL的`area25-rtl-cg-low/high`比较，归一化运行路径后脚本差异只有以下三个设置：

```tcl
set_db syn_generic_effort high
set_db syn_map_effort high
set_db syn_opt_effort high
syn_generic
syn_map
syn_opt
```

| 同一历史RTL、16ns综合目标 | low | high |
| --- | ---: | ---: |
| 综合面积，含SRAM | 2.649413mm² | 2.518886mm² |
| 按20ns报告的setup slack | +4.0051ns | +4.0031ns |

面积减少**0.130527mm²，约4.93%**，报告时序基本相同。low/high脚本都已有门控设置，不能把该组差异解释为“high才开启时钟门控”。High投入更多逻辑优化和映射搜索，并不改变RTL功能，代价通常是更长运行时间；此处没有对运行时间作量化结论。

另外一组较早RTL为2.680148→2.533809mm²，约降5.46%，不能与上组混为同一次实验。**最终r3已经将generic/map/opt三个effort全部设high**，因此现在再次“开high”没有这笔可重复领取的收益。

证据：工作区`eda-runs/20261107-area25-rtl-cg-low/synth.tcl`与`...-high/synth.tcl`；历史汇总`eda-runs/20261111-historical-report-cleanup/area25_area_validation.json`。

## 3. SRAM不加halo、不cutRow会在哪里出问题

这两个操作作用不同，不能互相替代，也不是所有宏在任何布局中都必须使用同样数值。

| 操作 | 防止什么 | 缺少时最先可能暴露的阶段 |
| --- | --- | --- |
| `addHaloToBlock` | 为宏边缘、尤其信号pin侧保留标准单元空间 | 放置后局部密度过高；详细布线时pin access、拥塞、绕线和间距问题 |
| `cutRow` | 删除宏完整边界及必要余量内的合法单元放置row | placement/合法化，或PG接入、布线及最终GDS检查出现宏边缘M1间距问题 |

本SRAM的LEF **OVERLAP相对完整外轮廓内缩5.2µm**。只按内缩轮廓判断合法位置，可能允许标准单元或row供电过于靠近宏真实金属；Innovus抽象中看似可用的位置，实际GDS不一定满足间距。没有cutRow不必然让放置器把cell放进宏，但不能据此保证真实宏边缘安全。

实际采用：

```tcl
placeInstance $name $x $y $orientation -fixed
addHaloToBlock $left $bottom $right $top $name -snapToSite
# mx0/my0/mx1/my1来自实际宏完整box：
cutRow -area [list [expr {$mx0-0.50}] [expr {$my0-0.50}] \
                  [expr {$mx1+0.50}] [expr {$my1+0.50}]]
```

普通侧halo为5.2µm，信号侧12µm；考虑内缩关系，信号侧在完整轮廓外约留6.8µm。cutRow按完整box外扩0.5µm处理。Halo是放置约束，不是禁止所有金属穿过宏的route blockage；cutRow也不会删除宏内部金属。

**项目实际遇到的现象：** 早期Calibre报270处M1.S.1，集中两块SRAM各135处。原厂SRAM GDS单独检查0，PNR导出已有270，Dummy后仍270，定位到PNR宏周边新增PG/M1/via接入问题。后续重做宏周边布局、PG与ECO后为0。记录不足以证明“只补halo”或“只cutRow”就独立消除了270处，因此不能作这种归因。

## 4. DRC具体怎么修

方法是定位真实导体→最小范围修改→重新布线/导出→复查。删除marker、放宽规则或只让命令返回成功都不算修复。

| 实际问题 | 具体修法 | 验证 |
| --- | --- | --- |
| Native PG过孔重叠，58处 | 删除VDD上两组重复19-cut VIA12阵列，位置约(1059.48,129.36)、(1099.48,129.36)µm；保留同网18/25-cut阵列和上下层电源金属 | native DRC＋VDD/VSS special connectivity |
| TCK PAD外侧多余绕线，4处 | 断言该外部net只有一个PAD.PAD端点且与top port物理重叠，定向删除冗余regular wire/via；不删除内部TCK树 | 信号连通＋DRC＋JTAG回归 |
| 底边reset接入，1处 | 在旧site加blockage，移动CPU `mem_reg[6][7]`触发器，`ecoPlace`合法化、重接PG、`ecoRoute` | placement＋DRC＋setup/hold |
| Calibre M2.S.2，1处 | 在底边PVSS2CDG实际宽M2附近增加METAL2信号禁布区(849,114.8)–(911,115.8)µm，只重布一条CPU网络 | 实际GDS完整DRC，r2/r3该项0 |
| WB CB.S.2.M5/M6，5处 | 读取37个Bond真实M5/M6边界，按朝向变换、外扩2.5µm；加74个信号禁布区，保留PG；重布4条CPU数据网、0条clock | 定向检查后重跑完整DRC/LVS/antenna/WB，最终WB0 |
| IO CO.R.4 | 项目私有OA的`B776_POSTVDD2CDG`一块PIMP右边从52.3扩到52.59µm，其他边不动，补齐接触/电阻POLY覆盖 | CO.R.4为0；此为IO几何修补，需库/工艺负责人认可 |
| Seal Ring seam/尺寸 | 用原生1µm边单元补齐接缝、增删边实例，禁止缩放工艺图形 | SR.S.1为0，物理外框1980×1980µm |
| M5/M6、OD密度不足 | 按实际六金属工艺生成Metal和OD/PO Dummy并合并最终GDS | postDummy M5.R.1/M6.R.1/DOD.R.1为0 |

M2修复的核心操作：

```tcl
createRouteBlk -name CALIBRE_M2_PAD_SPACING -layer METAL2 \
    -exceptpgnet -box {849.0 114.8 911.0 115.8}
# 核对受影响net、排除PG/clock，再定向删除旧regular wire/via。
ecoRoute
verify_drc -check_only default -report <native_drc.rpt>
# 重新导出真实GDS，继续跑Calibre；不能只停在native检查。
```

**创建blockage不会自动移动既有违规线。** 必须受控重布，并在ECO后重查setup/hold。Native DRC归零也不代表Calibre和WB归零，因为实际IO/Bond GDS包含抽象LEF未完整表达的几何。

最终状态：native DRC0；完整Calibre按课程四类单列后剩余0，但原始DRC并非0；天线62项0、WB64项0。严格LVS的IO电阻偏差和ERC7层次/977展开仍待评审，不写成正式签核全部通过。

详细过程、原始报告路径及未解决项见[完整复盘](backend-rf1r1w-r3-full-process.md)；逐组命令解释见[后端Tcl/GUI教程](backend-tcl-gui-tutorial.md)；成功ECO代码见[验证脚本目录](../eda/tsmc180/fullchip/verified_die1950_ecos/README.md)。
