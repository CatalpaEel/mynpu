# 当前RTL的完整ASIC后端复跑（2026-11-18）

基于main `53655b5`，包含FPGA优化时修改的共享XBAR、多操作数读回和流FIFO RTL。重新综合、带PAD布局布线，并对本次最终GDS完成Seal Ring、Dummy及Calibre检查；没有复用旧版核心网表或旧版签核结论。

**核心物理检查及课程排除项之外的DRC、天线、WB通过，教学容差LVS为CORRECT；严格LVS属性差异和ERC残项仍保留，不能称为正式投片签核全部通过。**

## 输入与结果

沿用TSMC180 TT、18ns综合目标/20ns报告、high effort、门控时钟及计算单元边界保留。RF 256B、Matrix/CNN/Vector队列4/4/4、四条8-word数据FIFO，Matrix 4×4、CNN DOT9、Vector计算能力不变。1950µm die，9信号PAD，无GPIO、外部Host、外部DMA。

| 指标 | 本次最终r1 | 旧版2026-11-10 r3 |
| --- | ---: | ---: |
| 综合cell面积，含两块SRAM，不含PAD | 2.569738mm² | 2.569286mm² |
| PNR核心非filler面积，含SRAM、不含外围IO | 2.634323mm² | 2.632349mm² |
| Die | 1950×1950µm | 1950×1950µm |
| Seal Ring物理外框 | 1980×1980µm | 1980×1980µm |
| 50MHz布线后setup WNS | +0.457ns | +0.468ns |
| 布线后hold WNS | +0.020ns | +0.018ns |
| 原生DRC / 核心PG问题 / 天线 | 0 / 0 / 0 | 0 / 0 / 0 |
| Calibre DRC，课程排除项之外 | 0 | 0 |
| Calibre天线 / WB展开违规 | 0 / 0 | 0 / 0 |
| 教学PR容差LVS | CORRECT | CORRECT |
| 严格LVS | IO PR电阻属性不匹配 | 同类限制 |
| ERC | 7个层次结果，展开977个 | 同类型、同数量 |

本次综合面积仅增加约0.000452mm²；PNR核心面积增加约0.001974mm²（约0.075%）。FPGA LUT优化没有变成显著的ASIC面积节省，也没有明显增加ASIC面积。

核心标准单元面积为1.831436mm²，SRAM为0.802887mm²。core filler另占0.207747mm²。外围IO原生单元并集面积0.8441mm²；不能把包含重叠Bond PAD的bbox面积直接相加作为整片利用面积。

## 实际执行与修复

1. **冻结与综合。** `prepare_run.py`冻结70份源码和生成顶层，共71个编译输入。Genus 19.17初次解析失败：`dm_top.sv`与`dm_sba.sv`的`master_r_error_i`有输入端口默认值。所有使用实例已显式接线，去掉这两处默认值后重新冻结为core-r1；未改变错误返回功能。RTL运行态JTAG/SBA、综合网表JTAG及MNIST均通过。
2. **封装及floorplan。** 从新核心网表生成9信号PAD封装，保留原映射；执行1950µm floorplan、SRAM halo/cutRow、电源规划和well tap。电源规划DRC为0。没有采用后续左侧JTAG/PAD试验或GPIO设计。
3. **布局、CTS。** 布局完成后未放置实例与核心放置违规均为0。布局日志保留IMPSP-9099：库中scan型触发器未定义scan chain，本设计没有实现扫描测试链。它不等于实际放置不合法；没有通过屏蔽诊断来声称具备DFT能力。
4. **hold修复。** CTS后hold最差−0.563ns、106条违规；专门post-CTS修复后违规为0。详细布线引入33条hold违例，最差−0.015ns。`optDesign -postRoute -hold`以0.02ns为目标，禁止恶化setup TNS；最终hold为+0.020ns、setup为+0.457ns，两者TNS与违规路径数均为0。
5. **天线、filler、连接。** 路由首轮58处天线违规，经天线修复后为0。补filler、增量路由与PG trim后，原生DRC和核心PG问题为0。本轮未出现需要套用旧版“两处PG重叠”或旧版M2指定网络ECO的情况。信号连接报告保留VDDPST/VSSPST两条“无路由”提示：这些是原生IO单元相邻金属接触形成的电源环；IO拼接审计通过，LVS拓扑匹配。保守的whole-chip closure字段仍为false，单列的core physical closure为true。
6. **初次Lab 5。** 用新GDS生成7844实例的Seal Ring、POC和私有IO PIMP补丁，生成金属与OD/PO Dummy。课程排除项之外的最终DRC为0，教学LVS为CORRECT，但WB有1处`CB.S.2.M6`。坐标约x=792.533–797.307µm、y=73.160–74.490µm，对应Bond金属与信号金属间距不足。
7. **本次r1物理ECO。** 另建fullchip-r1，保留首轮产物；按经过拓扑检查的方式清理外部PAD冗余走线，并按37个Bond PAD实际M5/M6边界加2.5µm routing keepout。只发现1条受影响非时钟网络：`i_soc/i_core_i_cpu/core_i_id_stage_i_n_48803`。仅该网重布，未删改单元或内部连接。原生DRC、时序和门级功能重新通过；导出新GDS后，**重新执行整套Lab 5**，WB最终为0。
8. **边界诊断。** OA顶层bbox显示右边界1975.001µm，起初疑似几何越界；只读检查确认越界对象全部是TEXT层实例/Bond名称标签，没有金属或实例越界。物理Seal Ring仍为(-15,-15)–(1965,1965)，1980µm见方。不能把文字标签bbox当作制造边界。

## 功能与签核边界

- CPU/NPU运行期间真实JTAG/SBA：1161项检查，2278次grant对应2278次reply，无halt绕行。
- 新核心综合网表JTAG：34项；MNIST门级样本：12项；均通过。
- 新封装映射、布线后及最终ECO网表JTAG/MNIST：各34项通过。最终网表回归没有回标SDF；STA使用布线提取数据。
- 严格LVS源/版图拓扑匹配，但保留51个IO PR电阻属性差异；教学检查使用原课程3.48%电阻容差，完整保留严格报告，没有修改共享PDK或把严格失败标成通过。
- ERC：`mnpg` 4/832，`floating.nxwell_float` 1/72，`floating.psub_float` 1/1，`npvss49` 1/72（层次/展开）。这些IO/衬底结果仍需课程或工艺负责人评审，没有自动豁免。
- DRC排除项为课程沿用的DRM、ESD、MOM、LUP，原始非零规则及数量保留在机器报告中。因此“DRC为0”专指排除项之外，不是原规则集全部为0。
- 仅TT单角；未做Dummy后PEX/STA、多角、IR/EM，也没有新的实板验证。

## 可复查文件

项目内：

- [汇总与70份源码SHA256](../reports/asic_main53655b5_20261118_validation.json)
- [最终PNR原始检查索引](../reports/main53655b5_20261118_r1_fullchip_validation.json)
- [最终Lab 5检查索引](../reports/lab5_main53655b5_20261118_r1_validation.json)
- [资源、时序、DRC/LVS/ERC报告副本](../reports/asic_main53655b5_20261118/)
- [本次实际执行的物理ECO脚本](../eda/tsmc180/verified_main53655b5_20261118/)

服务器运行目录位于仓库同级`../eda-runs/`：

| 目录 | 内容 |
| --- | --- |
| `20261118-main53655b5-core/` | 首次端口默认值语法失败，保留诊断 |
| `20261118-main53655b5-core-r1/` | 最终核心综合、输入快照、约束、网表 |
| `20261118-main53655b5-fullchip/` | 新版首次完整PNR |
| `20261118-main53655b5-fullchip-r1/` | 最终WB ECO、数据库及GDS/DEF/SPEF/SDF/网表 |
| `20261118-main53655b5-lab5/` | 首轮Lab 5，WB 1处 |
| `20261118-main53655b5-lab5-r1/` | 最终Seal Ring/Dummy、Calibre、OA数据库 |
| `20261118-main53655b5-orchestration/` | 驱动脚本、执行日志、完整性审计与归档 |

最终交付包在Lab5-r1的`deliverables/mynpu_main53655b5_20261118_design_and_reports.tar.gz`，附`SHA256SUMS`与读回验证。共享库不打包，路径及哈希保留在manifest。大型GDS、OA/Innovus数据库与PDK不提交Git。

在图形终端打开本次最终版图：

```bash
cd /home/s2400012841/chip-fullstack-2026/eda-runs/20261118-main53655b5-lab5-r1/workspace
virtuoso &
```

选择`mynpu_lab5_final → mynpu_asic_top → layout`。原有2026-11-10 r3 OA数据库仍是旧版，未覆盖。
