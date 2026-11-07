# 4×4外积版综合面积与时序

RTL检查点 `14260a5`。与旧点积Matrix、同样带共享QT01的版本比较。

| 项目 | 旧点积版 mm² | 4×4外积版 mm² |
|---|---:|---:|
| 默认优化总面积 | 2.586795 | 2.976653 |
| 标准单元 | 1.783907 | 2.173766 |
| 两块SRAM宏 | 0.802887 | 0.802887 |

总面积增加 **0.389859mm²（15.07%）**。包含两块SRAM，不含PAD、CTS、布线、filler或放置留白。

相对3mm²单元面积预算仅余 0.023347mm²；布线与时钟树后的完整芯片能否放下仍需PNR验证。

| Matrix分项（保留计算核层级） | 旧点积版 mm² | 4×4外积版 mm² |
|---|---:|---:|
| 纯计算核 | 0.058265 | 0.263470 |
| Stream供数/寻址/写回 | 0.052017 | 0.209350 |
| Matrix合计 | 0.110282 | 0.472820 |

保留层级版总面积为2.970777mm²，默认版为2.976653mm²；两版跨层级优化不同，分项不与默认总数混加。

## 时序

使用与基线相同的TSMC180 TT库与约束：16ns优化、20ns报告。50MHz系统时钟综合setup slack **+4.0012ns**，TNS **0.0000ns**，违反路径 **0**。
这是综合、布局前时序估算，尚未执行新版本CTS、布线或物理时序签核。

关键路径摘要：

- Path 1: MET (4001 ps) Setup Check with Pin i_core/i_quant/product_reg[63]/CP->D
- Startpoint: (R) i_core/i_stream_i_engine/output_final_reg/CP
- Endpoint: (F) i_core/i_quant/product_reg[63]/D

## 模块面积（保留层级版）

| 模块 | 面积 mm² |
|---|---:|
| SRAM macros | 0.802887 |
| Matrix | 0.472820 |
| XBAR | 0.426185 |
| CPU | 0.294523 |
| CNN | 0.270238 |
| MMIO / task queues | 0.261646 |
| Vector | 0.196751 |
| Shared quantizer | 0.136063 |
| JTAG / debug | 0.105130 |
| Top / core glue | 0.004533 |

已逐项核对当前冻结RTL与20组功能回归、历史基线RTL与其功能报告、工艺库哈希及SRAM宏包装器。没有把新版本RTL与旧面积数字混用。

[机器报告](../reports/matrix_outer4_area_validation.json)。原始报告：
- [20261107-outer4-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area/reports/area.rpt)
- [20261107-outer4-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area-hier/reports/area.rpt)
- [20261107-shared-quant-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area/reports/area.rpt)
- [20261107-shared-quant-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area-hier/reports/area.rpt)
- [当前50MHz timing.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area/reports/timing.rpt)

复现汇总：

```bash
python3.12 npu/eda/tsmc180/collect_outer4_area.py --run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area \
  --hier-run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-outer4-area-hier --baseline-run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area \
  --baseline-hier-run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-quant-area-hier
```
