> 本页为VPG1宽Vector的历史综合。当前[32位VPG2](vector32.md)尚未重新测量面积。

# 当前并行版本面积测量

2026-11-07，Genus 19.17、TSMC180 TT、low effort综合。16ns优化、20ns报告，256B RF、8/8/8任务队列、两块真实8KB SRAM。统计为Cell Area，不将Net Area相加；不含PAD、CTS、布线、filler或放置留白。

普通优化版：**2.912516 mm²**，其中标准单元**2.109629 mm²**、SRAM宏**0.802887 mm²**。相对旧版2.676600 mm²增加**0.235916 mm²（8.81%）**。50MHz综合setup slack为+4.0062ns、TNS为0。这些是综合结果，不能作为布线后签核或2×2mm²含PAD可放入的保证。

保留CNN、Matrix和第二Vector轻量核边界的版本总面积为**2.911166 mm²**，与普通版相差0.001350 mm²（约0.046%）。下表按此版本统计，互不重复：

| 部分 | 面积/mm² | 占比 |
|---|---:|---:|
| 两块SRAM宏 | 0.802887 | 27.58% |
| XBAR（含RF、流FIFO、缓存和仲裁） | 0.781586 | 26.85% |
| Vector计算与供数 | 0.309031 | 10.62% |
| CPU | 0.294710 | 10.12% |
| CNN计算与供数 | 0.265545 | 9.12% |
| MMIO与任务队列 | 0.243575 | 8.37% |
| Matrix计算与供数 | 0.106041 | 3.64% |
| JTAG与Debug | 0.104790 | 3.60% |
| 顶层连接与复位等 | 0.003001 | 0.10% |
| 合计 | 2.911166 | 100% |

XBAR内部拆分（已包含在上表XBAR内，不能再相加）：
- `shared_rf_mm2`：0.350516 mm²。
- `stream_fifo_mm2`：0.257102 mm²。
- `sram_read_cache_and_arbitration_mm2`：0.173967 mm²。

计算核与供数进一步拆分：

- `i_core_i_stream_i_engine`：0.158781 mm²。
- `i_core_i_cnn`：0.059788 mm²。
- `i_core_i_stream_i_control`：0.046975 mm²。
- `i_core_i_matmul`：0.058298 mm²。
- `i_core_i_matrix_stream`：0.047743 mm²。
- `i_core_i_vector`：0.176657 mm²。
- `i_core_i_vector_stream`：0.114989 mm²。
- `i_core_i_vector_light`：0.017386 mm²。

普通版RF模块从0.217529增至0.350874 mm²，增加约0.133345 mm²，占总增量约56.5%；主要增长集中在新增请求选择、仲裁与返回路径，RF容量不变。

原始报告：
- [20261107-shared-parallel-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-parallel-area/reports/area.rpt)。
- [20261107-shared-parallel-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-parallel-area-hier/reports/area.rpt)。

[机器汇总](../reports/shared_parallel_area_validation.json)。两份运行的源码清单一致，冻结输入、当前RTL和工艺库哈希均已复核。

复现统计：

```bash
python3.12 npu/eda/tsmc180/collect_module_area.py --run /home/s2400012841/chip-fullstack-2026/eda-runs/20261107-shared-parallel-area-hier --out npu/reports/shared_parallel_area_hier.json
```
