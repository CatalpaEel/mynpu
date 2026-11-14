# 文档索引

[项目首页](../../README.md)描述当前默认版本；[源码导航](../rtl/README.md)和[build_config.json](../build_config.json)是实现入口。
本次移除已撤回实验、旧ABI迁移和重复阶段面积文档；原文仍可通过Git历史获取。当前版本机器验证报告保留在`../reports/`，旧版本数据已删除。

## 后端专题教程

- [面积优化与DRC修复简报](backend-area-drc-brief.md)：设计减面积、Genus low/high实测、SRAM halo/cutRow作用及具体DRC修法。

- [Tcl命令、每组操作的数据库变化与GUI观察](backend-tcl-gui-tutorial.md)：从综合到最终GDS，按阶段说明目的、命令、前后变化与检查方法。

## GPIO加入前的完整实现复盘

- [完整流程、参数与问题处理记录](backend-rf1r1w-r3-full-process.md)：综合压面积、两轮hold、原生/Calibre/WB修复、Seal Ring/Dummy、LVS/ERC与未解决项。

## 当前证据

- [JTAG-only仿真与Host移除](jtag-only-simulation.md)：CPU运行态SBA竞争、DM错误回传、子字访问和计时口径。

- [左侧JTAG与电源/地成对PAD试验](jtag-left-paired-pads.md)：原生PNR及34项JTAG验证通过，尚未重跑Calibre/LVS。

- [RF 1R1W实现与性能](rf1r1w.md)：端口协议、同址读写、微基准及MNIST。
- [RF 1R1W最终后端r3](rf1r1w-die1950-signoff.md)：最终面积、时序、物理修复和签核限制。

## 软件与接口

- [通用任务层](general-workloads.md)：GEMM、向量、布局、归约、卷积和图调度的实际覆盖范围。
- [LY01布局与EV01事件](layout-events.md)：步长、输出布局、依赖与计数。
- [字节码布局](command-layout.md)：基础任务编码；后续扩展结合LY01/EV01与当前`npu.h`查看。
- [配置时序由软件负责](software-owned-config.md)：运行中修改配置的责任与限制。
- [SYNC v2与流水优化](throughput-optimization.md)：派发、量化、写回进度及同步语义。
- [独立IRQ](irq-independent.md)、[JTAG/DebugModule](jtag.md)：调试与中断机制；当前SoC测试统一经JTAG SBA，Host接口已删除。

## 计算与互联专题

- [Matrix外积](matrix-outer4.md)、[Vector SIMD](vector-simd.md)、[可选共享量化](shared-quant.md)。
- [XBAR流转发](xbar-stream-routes.md)、[软件管理RF与无SRAM缓存](no-sram-cache.md)。

专题文档保留接口与实现机制；测量入口仅使用当前版本。
最新默认为任务队列4/4/4、流FIFO各8 words、256 B RF各bank 1R1W；最新物理证据仅使用上方最终r3报告。
