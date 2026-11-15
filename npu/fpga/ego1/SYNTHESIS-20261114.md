> 本文保留ba23677基线实测；最新本地优化结果见[LUT优化报告](LUT-OPTIMIZATION-20261114.md)。

# 当前main：Vivado 2025.2完整综合及LUT检查

2026-11-14，源码提交`ba23677`，无GPIO、无Host。**完整综合通过，但标准opt_design后仍触发UTLZ-1资源超限，尚不能认定XC7A35T放得下。**

本次采用板测方向的FPGA配置，而不是不带参数的默认构建：

- 器件`xc7a35tcsg324-1`，系统10MHz。
- `--area-medium --cpu-rf-lutram --cnn-dsp --threads 4`。
- RF/队列/计算规模保持主线；没有修改共享RTL或关闭LUT资源检查。

| 阶段 | 总Slice LUT | 其中Logic LUT | LUTRAM | FF | RAMB36 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 完整综合 | 21217 | 21081 | 136 | 14196 | 4 | 58 |
| 标准opt_design（ExploreArea） | 20956 | 20820 | 136 | 14196 | 4 | 58 |
| 器件容量 | 20800 | 20800 | 9600 | 41600 | 50 | 90 |

总LUT优化后仍超156个（约0.75%）；Logic LUT超20个，默认`UTLZ-1`仍为Error。运行时查询`drc.disableLUTOverUtilError=0`。普通DRC警告也保留，没有把“命令正常结束”解释为DRC通过。

综合run正常完成：0错误、0严重警告、411个普通警告。预布局时序setup WNS +66.116ns、hold WNS −1.003ns，属于综合网表估算，不代表布线后的setup/hold闭合。没有执行place/route、生成新bitstream或连接实体板。

旧板测版本的综合21115 LUT、最终实现19799 LUT只能作为阶段区别的例子；它使用Vivado 2023.2和旧源码，不是当前版结果。当前版是否能通过进一步物理优化/打包放入器件，仍需实际验证。本轮保持默认资源检查，未使用推迟容量检查的可选实验开关。

## 证据位置

运行目录：`/home/s2400012841/chip-fullstack-2026/eda-runs/20261114-ego1-main-ba23677-vivado2025-synth10/`。

- `measurement.json`：指标、配置、冻结源及报告哈希。
- `source_manifest.json`：完整输入快照清单。
- `reports/utilization_synth_flat.rpt`、`utilization_opt_flat.rpt`：实际资源表。
- `reports/utilization_opt_hier.rpt`：模块资源分布。
- `reports/drc_synth.rpt`、`drc_opt.rpt`：默认UTLZ-1及其他规则结果。
- `reports/timing_synth.rpt`：预布局时序。
- `project/ego1_mynpu.runs/synth_1/ego1_soc_top.dcp`、`impl_1/ego1_soc_top_opt.dcp`：综合/优化检查点。

结果提取时发现`open_run impl_1`不能打开仅完成opt_design、尚未开始place的run；改用`open_checkpoint`读取已成功生成的opt DCP。没有因此重做优化或更改网表。
