# 从RTL到GDS/Calibre：本工作区GUI运行教程

这是一套TSMC180 **ASIC** 后端教程，使用Genus、Innovus、Virtuoso与Calibre；不是Vivado FPGA流程。你会在GUI命令区逐阶段执行Tcl，观察结果后再进行下一阶段。生成的GUI脚本移除了批处理末尾的`exit`，不会自动关闭窗口。

准备状态：核心输入与签核模板已冻结，尚未运行任何设计综合/PNR/签核。参考结果来自2026-11-18，不能拿来代替本次检查。RF 256B、任务队列4/4/4、流FIFO四通道各8 words，9信号PAD，无GPIO/Host。综合目标18ns，最后按20ns（50MHz）检查；1950µm die，物理Seal Ring外框1980µm。

## 0. 图形终端、预检与目录

在服务器远程桌面的终端执行：

```bash
cd /home/s2400012841/chip-fullstack-2026/mynpu-backend-gui-20261119
python3.12 backend_lab/lab.py preflight
python3.12 backend_lab/lab.py status
```

`preflight`仅检查工具PATH、库文件、RTL哈希，不启动EDA计算。GUI需要有效`DISPLAY`；启动脚本在无显示环境时会提示退出。沿用服务器已有许可证环境，不需要sudo。

以下“终端”指Linux shell；“Genus/Innovus控制台”指工具GUI里的Tcl命令区。不要把`source *.tcl`放到Linux shell执行，也不要把Python命令贴进Tcl区。

目录含义：`backend_lab/runs/core`是核心综合；`runs/chip`是封装及物理实现（综合后才生成）；`runs/signoff`是Seal Ring/Dummy/Calibre。每一步应等待控制台重新出现提示符，遇到Error先查原因，不要一次性粘贴全部步骤。

## 1. Genus GUI：加载、展开、约束

终端：

```bash
backend_lab/bin/open_genus_core.sh
```

启动器使用本服务器Genus 19.17已核实的`-legacy_gui -log launcher`参数；没有加`-legacy_ui`，Tcl仍为`set_db`等Common UI命令。日志写入core目录的`launcher.log`，不要同时再开一份GUI写同一个日志。

Genus控制台：

```tcl
source gui_01_setup.tcl
```

这一组包含：读取标准单元/SRAM的Liberty与LEF、`read_hdl`、`elaborate`、`check_design`、`read_sdc`、high effort设置、门控时钟提取与计算单元边界保留。

看什么：Hierarchy里应有CPU、Debug、XBAR、CNN/Matrix/Vector及两块SRAM；展开检查不能有未解析模块。此时仍是RTL展开结果，不是最终单元面积。

报告：`reports/elaborated_check.rpt`、`reports/elaborated_unresolved.rpt`。两处Debug输入端口默认值兼容修复已包含在工作区中，不需要你再次改RTL。

## 2. Genus GUI：三步综合

在同一Genus会话依次执行，每一步结束后看报告：

```tcl
source gui_02_generic.tcl
```

`syn_generic`做工艺无关逻辑优化和运算结构选择。输出`reports/generic_area.rpt`；这个阶段的通用逻辑面积不能当成最终标准单元面积。

```tcl
source gui_03_map.tcl
```

`syn_map`映射到TSMC180实际单元，输出`mapped.v`、`reports/mapped_area.rpt`和`mapped_qor.rpt`。在Hierarchy/Schematic观察乘法、寄存器、选择器被映射成什么。面积表的Cell Area与Net Area分开，父层包含子层，不要重复相加。

```tcl
source gui_04_opt_export.tcl
```

`syn_opt`进一步优化；输出`optimized.v`、`optimized.sdc`、`optimized.db`及最终area/timing报告。优化用18ns，`reports/timing.rpt`切到20ns后报告，两个约束阶段不可混淆。Genus报告可能以ps显示，先看单位。

成功执行到最后会打印`DUAL_BANK_ASIC_SYNTH_PASS`，并生成`gui_complete.txt`。这仅说明命令完成；仍要看未解析、面积和时序，不是物理签核通过。

终端（可在另一个终端运行）：

```bash
python3.12 backend_lab/lab.py accept-core
python3.12 backend_lab/lab.py prepare-chip
```

`accept-core`检查真实工具日志中的完整完成行以及输出文件；`prepare-chip`冻结这个新网表和9信号PAD封装，不会借用旧网表，不启动综合。不要修改冻结输入后仍沿用旧网表；若要改RTL请建立新的运行目录。

可选门级功能验证（实际运行VCS）：

```bash
python3.12 npu/scripts/run_gate.py --run backend_lab/runs/core --suite jtag --tag gui-lab-core-jtag
python3.12 npu/scripts/run_gate.py --run backend_lab/runs/core --suite latency --tag gui-lab-core-mnist
```

## 3. Genus GUI：封装综合

关闭或保留前一个Genus窗口，另开封装综合会话：

```bash
backend_lab/bin/open_genus_chip.sh
```

它的工作目录是`runs/chip/mynpu/chip_synth`。在这个Genus控制台执行完整路径：

```tcl
source /home/s2400012841/chip-fullstack-2026/mynpu-backend-gui-20261119/backend_lab/runs/chip/scripts/gui_synth_chip.tcl
```

脚本读取新核心网表及壳层，保留核心映射，综合封装并输出`mynpu_asic_top.postsyn.v`。不要把壳层综合面积与核心综合面积混为一谈，真实PAD实例在Innovus floorplan阶段加入。

完成后终端执行：

```bash
python3.12 backend_lab/lab.py accept-chip
backend_lab/bin/open_innovus.sh
```

## 4. Innovus GUI：floorplan、SRAM与PAD

Innovus启动于`runs/chip`。先加载观察与截图辅助命令：

```tcl
source scripts/gui_restore.tcl
source scripts/gui_pnr_01_floorplan_io.tcl
```

它读取新封装网表、LEF和MMMC；`init_design`建立数据库，`floorPlan`定义1950µm die和core；固定两块SRAM、设置halo、`cutRow`清掉宏下方的标准单元行；生成9信号PAD、电源/地/POC/角单元、Bond与IO filler。

GUI观察：按`fit`看完整die，显示Rows和Blockages；SRAM信号侧朝内，不能只看LEF的OVERLAP内框判断宏占地。检查PAD方向、供电分组和外部port→PAD→内部网络的关系。PAD/Bond的设计重叠与核心单元非法重叠是两类检查。

保存的检查点：`03_io_floorplan.enc.dat`。报告：`floorplan_geometry.rpt`、`floorplan_check.rpt`。可截图：

```tcl
lab_snap 01_floorplan
```

`lab_snap`调用实际GUI的`gui_dump_picture`，输出到`backend_lab/screenshots/`；不会覆盖同名图片。不要把示意图当成运行截图。

## 5. 电源规划

```tcl
source scripts/gui_pnr_02_powerplan.tcl
lab_snap 02_power
```

先绑定VDD/VSS，再添加电源环、stripe、SRAM供电接入与well tap。GUI里单独显示Special Nets，区分PG与普通信号，逐层观察M1–M6。halo空白不是电源开路，必须看真正的PG pin及过孔连接。

检查`06_powerplan_drc.rpt`、`06_core_pg.rpt`、`06_welltap.rpt`。保存`06_powerplan.enc.dat`。原生IO的VDDPST/VSSPST可能出现“无routing”提示，不能简单屏蔽；后续还需IO拼接审计与Calibre LVS验证。

## 6. 放置、PAD调整、tie单元

```tcl
source scripts/gui_pnr_03_place.tcl
lab_snap 03_place
```

`place_opt_design`完成时序/拥塞驱动布局；脚本还会按本工程受约束PAD计划处理PAD、加入tie单元。可关掉信号线，只显示标准单元和宏；看宏边缘、通道、局部热点，不要仅凭一张全局图判断密度。

检查`07_place_check.rpt`、`08_post_tie_place.rpt`与`preCTS/`。未放置实例、核心放置违规应为0。库中scan型触发器可能引起IMPSP-9099诊断：本工程未实现扫描链，保留该限制，不能声称已完成DFT。检查点为`07_placed`和`08_post_tie`。

## 7. CTS与hold修复

```tcl
source scripts/gui_pnr_04_cts.tcl
lab_snap 04_cts
source scripts/gui_pnr_04b_holdfix.tcl
```

`ccopt_design`插入并优化时钟树；之后`optDesign -postCTS -hold`修复短数据路径。GUI里分别看clock nets和signal nets，时钟树skew与hold slack不是可直接相减的两个余量：hold检查已经包含路径时钟到达差。

检查`postCTS/`、`postCTS_hold/`以及`postCTS_holdFix_setup_check/`、`postCTS_holdFix_hold_check/`。修hold不能牺牲setup TNS。本次脚本保留原验证过的时钟参数，不为了让报告好看而关闭不确定度。

检查点：CTS后`10_post_cts`，hold修复后`11_pre_route`。

## 8. 详细布线

```tcl
source scripts/gui_pnr_05_route.tcl
lab_snap 05_route
```

路由范围为M2–M6，完成详细布线、天线修复和寄生提取。GUI逐层看线、via和拥塞；初期估计overflow不是最终DRC。

检查`12_route_drc.rpt`、`12_route_antenna.rpt`、`postRoute/`及`postRoute_hold/`。布线后可能重新出现hold违例，下一步会针对真实寄生修复；不要停在“布线命令成功”。保存`12_routed`。

## 9. post-route优化与最终物理检查

```tcl
source scripts/gui_pnr_06_finish.tcl
lab_snap 06_finish
```

GUI脚本会加载`gui_env.tcl`，补齐与批处理一致的设置：setup/hold修复均开启、setup目标余量0.30ns、hold目标0.02ns、优化密度上限0.99。不要漏掉环境设置，否则同一Tcl可能跳过post-route修复。

此步做post-route setup/hold优化、filler、增量路由与PG trim，保存`13_finished`。

必须核对：

| 检查 | 报告/条件 |
| --- | --- |
| setup/hold | `final_setup/`、`final_hold/`的summary：WNS≥0、TNS=0、违规路径0 |
| 原生DRC | `13_final_drc.rpt`无违规 |
| 核心PG连接 | `13_final_pg.rpt`无问题 |
| 放置合法性 | `13_final_place.rpt`未放置及核心违规0 |
| 天线 | `13_final_antenna.rpt`无违规 |
| 面积 | `13_implemented_footprint.rpt`分开standard、SRAM、filler、IO |

截图DRC位置时应同时显示相关两侧金属，不能只保留marker。不要按全局skew再次扣减hold WNS。

## 10. 导出GDS、网表、SPEF/SDF

```tcl
source scripts/gui_pnr_07_export.tcl
```

输出在`runs/chip/mynpu/pnr/outputs/final/`，含GDS.gz、DEF、flat LVS网表、hier post-PNR网表、SDC、SPEF.gz、SDF.gz和LEF；保存`14_exported`。导出脚本会合并原生标准单元、SRAM与IO GDS；只看到宏方框不是完整制造图形。

终端可做最终门级JTAG/MNIST测试：

```bash
python3.12 npu/scripts/run_chip_gate.py \
  --run backend_lab/runs/chip \
  --netlist backend_lab/runs/chip/mynpu/pnr/outputs/final/mynpu_asic_top.hier_postpnr.v \
  --tag gui-lab-routed
```

这项测试不回标SDF；布线时序看STA，二者不能互相替代。

## 11. Seal Ring、Dummy与Calibre

签核工作区已提前准备，但只有私有技术库/环参考、规则和空目录，没有旧设计GDS或旧检查结果。先在终端检查本次输入：

```bash
python3.12 backend_lab/lab.py ready-signoff
```

它核对原生DRC、核心PG、天线与最终setup/hold，检查IO拼接及导出文件，并为真实输入写SHA256。检查不通过会停止。然后执行：

```bash
python3.12 backend_lab/lab.py signoff
```

此阶段通过脚本执行v2lvs、Virtuoso导入/Seal Ring/POC、Dummy前DRC、金属与OD/PO Dummy、合并GDS、最终导入，以及严格LVS、教学容差LVS、最终DRC、天线、WB。命令会实际运行EDA。它不自动把失败报告改成通过，不修改共享PDK。

进度查看`runs/signoff/logs/`，最终JSON在`runs/signoff/outputs/signoff_validation.json`和`lab5_exercise_validation.json`。任何步骤失败先看对应`*-launcher.log`和JSON，不要删除失败记录后用旧产物继续冒充新结果。

Calibre检查命令在批处理运行，结果可以打开RVE GUI观察：在服务器终端启动`calibre -rve`，从结果浏览器打开相应`drc_post/results.db`、`antenna/results.db`、`wb/results.db`或`lvs/svdb`。不同检查的数据格式不同，不能拿DRC ASCII结果当LVS数据库。用报告中的cell名、层号和DBU定位，2000 DBU=1µm。

## 12. 如果出现与参考类似的WB问题

不要预先套用旧版PG/M2指定网络ECO。参考版曾有1处Bond M6间距违规；本次网名和坐标可能变化，必须先读自己的WB结果。

只有确认同类几何/拓扑后，在Innovus执行可选修复：

```tcl
source scripts/gui_cleanup_external_pad_routes.tcl
source scripts/gui_fix_current_bond_spacing.tcl
source scripts/gui_export_wb_final.tcl
```

第一步从13_finished恢复并保存13_padclean，仅清理通过拓扑核对的外部PAD冗余regular routes。第二步从13_padclean恢复，按37个Bond的实际M5/M6边界留2.5µm keepout，识别受影响网络、拒绝自动处理时钟，保存13_wb_fixed。第三步从13_wb_fixed导出。即使没有匹配问题也不要盲目运行来增加改动。

修复后重新检查时序/DRC/连接和门级功能，并为新GDS建立**新的signoff目录**；不能继续使用已有signoff的缓存结果。终端执行：

```bash
python3.12 backend_lab/lab.py prepare-signoff --signoff-name signoff-r1
python3.12 backend_lab/lab.py signoff --signoff-name signoff-r1
```

这会保留首轮，重新执行新输入的全部签核。更多ECO用signoff-r2等新名称。不要手改旧manifest哈希、伪造完成标记或覆盖旧签核证据。查看ECO后最终OA时，应进入对应`runs/signoff-r1/workspace`再启动Virtuoso；默认启动器仍打开初轮signoff。

## 13. 恢复检查点与截图

只想查看，不要再次source修改脚本：

```tcl
source scripts/gui_restore.tcl
lab_restore 03_io_floorplan
lab_restore 10_post_cts
lab_restore 12_routed
lab_restore 13_finished
```

每次restore会切换当前设计，建议不同窗口对比不同阶段；未保存的手工修改会丢失。截图例如：

```tcl
lab_snap 07_final_drc
```

想看最终制造几何，先等signoff导入完成，再从终端运行：

```bash
backend_lab/bin/open_virtuoso.sh
```

Library Manager：`mynpu_lab5_final → mynpu_asic_top → layout`，建议只读打开。`F`适配整图，显示下层实例后逐层查看。TEXT标签可能超出Seal Ring的显示bbox，不能因此认定金属越界；要检查对象类型和实际制造层。不要修改共享PDK的颜色/几何或覆盖原参考库。

## 14. 怎么判断跑完

应同时保留新源码/库manifest、核心/封装网表、各阶段数据库、最终GDS及输入哈希、门级测试结果和Calibre报告。

参考版可达到：综合约2.569738mm²，PNR核心约2.634323mm²，50MHz setup/hold约+0.457/+0.020ns，课程排除外DRC/天线/WB为0、教学LVS CORRECT。这些只是对照值，不是本工作区的预先验收结论。

严格LVS参考版仍有IO PR电阻属性差异，ERC有7个层次/977个展开结果。教学LVS沿用3.48%电阻容差；原始DRC的课程排除项为DRM/ESD/MOM/LUP。必须保留严格报告、原始非零规则与ERC，不得把课程检查通过写成正式投片签核全部通过。TT单角、无Dummy后PEX/STA、无IR/EM、多角与DFT，是本练习明确的范围。

## 15. 可选批处理入口

GUI与批处理择一完成某阶段，避免重复覆盖检查点。批处理备选：

```bash
python3.12 backend_lab/lab.py batch-core
python3.12 backend_lab/lab.py prepare-chip
python3.12 backend_lab/lab.py batch-chip
python3.12 backend_lab/lab.py batch-stage --stage 01
# 然后依次02、03、04、04b、05、06、07；每步检查报告。
```

已有日志/阶段记录时脚本会拒绝直接覆盖。不要同时让GUI和批处理修改同一运行目录。想重跑一轮请用新的独立工作区或新的运行路径。
