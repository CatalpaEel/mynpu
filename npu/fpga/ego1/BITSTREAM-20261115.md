# EGo1完整实现与bitstream（2026-11-15）

当前本地LUT优化版已完成布局、布线、setup/hold检查、默认DRC、bitstream与SPIx4 MCS生成。无GPIO、无外部Host。未连接板卡、未烧写、未进行新版实板测试。

使用Vivado 2025.2，器件 `xc7a35tcsg324-1`，EGo1 V2.2原引脚约束，系统时钟10MHz，外部JTAG约束1MHz。综合配置为area-medium、CPU RF LUTRAM和CNN DSP映射。基于ba23677加本地三份互联RTL修改，已逐项检查冻结输入SHA256与当前源码一致。

| 项目 | 结果 |
| --- | ---: |
| LUT | 19925 / 20800（95.79%） |
| FF | 13169 / 41600 |
| RAMB36 | 4 / 50 |
| DSP | 58 / 90 |
| setup WNS / TNS | +45.659ns / 0 |
| hold WHS / THS | +0.018ns / 0 |
| 完全布线网络 | 33890 / 33890 |
| 布线错误 | 0 |
| 默认DRC Error / Critical Warning | 0 / 0 |

opt_design的20573 LUT经布局优化进一步降至19925。默认LUT容量检查始终开启，没有放宽时序或DRC严重级别。报告仍有DSP流水、BRAM异步控制等Warning，应保留并审阅；生成bitstream不等于已通过板测或所有CDC功能验证。hold余量较小，改变RTL、约束或工具策略后必须重测。

## 文件位置

运行目录：

```
/home/s2400012841/chip-fullstack-2026/eda-runs/20261114-ego1-main-ba23677-onehot-fifo-v2/
```

- `ego1_mynpu.bit`：易失性FPGA配置文件。
- `ego1_mynpu.mcs`：8MB SPIx4配置镜像，起始地址0。
- `ego1_routed.dcp`：最终布线检查点。
- `implementation_pass.txt`：通过标记与时序余量。
- `reports/`：资源、时序、DRC、CDC与布线状态。
- `resume_bitstream.tcl`：从已有project/checkpoint继续实现的完整命令。
- `implementation_retry_launcher.log`：成功运行日志。

本次直接复用已验证的综合/opt检查点，执行 `launch_runs impl_1 -to_step route_design`，随后打开实现结果，导出报告，检查setup/hold和默认DRC，通过后执行 `write_bitstream` 与 `write_cfgmem`。没有再次综合或改动源配置。

项目内的机器可读结果、产物SHA256见 `npu/reports/ego1_bitstream_20261115.json`，报告副本和恢复脚本在同名目录；大体积bitstream/DCP留在上述运行目录。

DSP层次分配核对：CNN24、Matrix16、Vector5、CPU5、共享量化4、CNN Stream1、MMIO3，合计58。Matrix不是20个。
