# RTL 导航

生产RTL的唯一清单为[files.f](files.f)。新增/删除模块必须同步更新清单；测试台和生成物放在`tb/`、`build/`。
默认容量和队列配置来自[build_config.json](../build_config.json)，不能从历史报告推断。

| 目录 | 模块职责 |
| --- | --- |
| `top/` | `npu_core`集成CPU、MMIO、调试及计算单元；`npu_soc`接两块同步SRAM模型 |
| `debug/` | JTAG DTM、Debug Module、SBA桥和CPU bootstrap |
| `control/` | MMIO、任务队列、配置、计数器、IRQ、依赖事件及GPIO8寄存器 |
| `matrix/` | 4×4外积核与供数/写回Stream |
| `cnn/` | 3×3 DOT9核、窗口供数、任务控制与流引擎 |
| `vector/` | INT32/4×INT8 SIMD核、程序发射和供数Stream |
| `interconnect/` | XBAR、RF、流FIFO、多路读取 |
| `quant/` | CNN/Matrix共享可选量化QT01；支持原始INT32旁路 |
| `common/` | 地址包、仲裁、时钟门控和字节写合并 |

外部Host总线端口已删除；所有SoC级加载和控制测试经过JTAG TAP→DTM→DM SBA→XBAR master 3。独立计算/互联模块测试仍直接驱动其本地接口。

默认RF为256 B，8个物理bank各1R1W；gather请求仍共享读口并参与仲裁。
Matrix/Vector/CNN任务队列均4项；4条流FIFO各8 words。
计算核与地址/搬运控制分开，完整任务仍需要Stream和控制逻辑。

从仓库根目录执行：

```sh
python3.12 npu/scripts/gen_sources.py
```

生成`npu/build/sources.f`、`sources.tcl`和`asic_sources.f`。外部CPU和调试库按依赖顺序加入；配置宏随源清单生成。
ASIC流程会准备实际SRAM宏wrapper；FPGA板级入口见[EGo1说明](../fpga/ego1/README.md)。

接口说明见[布局与事件](../docs/layout-events.md)、[字节码](../docs/command-layout.md)、[RF 1R1W](../docs/rf1r1w.md)。
旧网表、数据库和报告保留当时路径与输入哈希；不能用路径兼容代替源码一致性验证。
