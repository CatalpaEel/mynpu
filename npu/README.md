# NPU 开发入口

整体架构和最新 ASIC 结果见[项目首页](../README.md)。本目录使用独立计算单元、软件任务调度及 RF 1R1W 设计。

## 目录

| 路径 | 用途 |
| --- | --- |
| `rtl/` | 当前生产RTL，模块导航见[说明](rtl/README.md) |
| `sw/` | MMIO API、任务图、C执行器及RV32汇编生成 |
| `mnist/` | 模型导出、固件与整数golden，见[说明](mnist/README.md) |
| `workloads/` | 通用算子组合负载生成 |
| `tb/`、`tests/` | RTL测试台与软件测试 |
| `scripts/` | 源清单生成、仿真及报告脚本 |
| `eda/tsmc180/` | ASIC综合、含PAD后端与检查流程 |
| `fpga/ego1/` | EGo1板级工程；Vivado实际执行尚待环境 |
| `docs/` | [接口与专题索引](docs/README.md) |
| `reports/` | 测量/验证证据，各自对应冻结版本 |
| `build/` | 本地生成物，Git忽略 |

## 配置与软件契约

[build_config.json](build_config.json)默认：RF每逻辑半区32 words，共256 B；Matrix/Vector/CNN任务队列4/4/4；流FIFO每通道8 words。
项目RTL清单维护在[rtl/files.f](rtl/files.f)，`scripts/gen_sources.py`会生成包含CPU/DebugModule依赖的VCS/Vivado/ASIC源清单。
不要使用旧根目录XPR推断本版板级实现状态。

软件入口是[sw/npu.h](sw/npu.h)、[sw/task_graph.py](sw/task_graph.py)和[sw/npu_plan.h](sw/npu_plan.h)。
配置没有全面的忙时写保护；软件必须通过启动票据、完成计数、IRQ和依赖事件安排安全修改。
队列空不等于所有计算、量化和写回应答已完成。详见[软件配置责任](docs/software-owned-config.md)、[同步进度](docs/throughput-optimization.md)与[布局事件](docs/layout-events.md)。

## 常用验证

从仓库根目录执行：

```sh
python3.12 npu/scripts/gen_sources.py
python3.12 npu/tests/test_task_graph.py
python3.12 npu/scripts/run_vcs.py --suite latency --tag local_latency
python3.12 npu/scripts/run_vcs.py --suite jtag --tag local_jtag
python3.12 npu/scripts/run_vcs.py --suite workloadcpu --tag local_workloads
```

`--tag`需要使用新名称。SRAM宏模型回归可加`--macro`，需要服务器对应工艺文件。
默认MNIST记录为21,008周期/张，见[RF验证](docs/rf1r1w.md)；旧DMA相关测试套件已退役。
本次文档整理不修改硬件、固件或重新测量PPA。
