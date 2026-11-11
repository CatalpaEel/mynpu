# MNIST 软件与整数推理

MNIST是当前硬件的一项完整回归负载。架构、配置及最终ASIC证据见[项目首页](../../README.md)，软件通用能力见[任务层](../docs/general-workloads.md)。

## 文件入口

| 文件 | 作用 |
| --- | --- |
| `export.py` | 模型/参数和整数参考导出 |
| `firmware.py` | RV32固件、任务描述及SRAM镜像生成 |
| `artifacts/` | 当前程序、参数、输入、逐层golden与元数据 |
| `../sw/task_graph.py` | 通用任务与图调度 |
| `../sw/npu.h` | MMIO与任务字段定义 |

默认固件使用共享QT01量化和完成IRQ/WFI等待。CNN执行卷积，Matrix执行FC，Vector执行必要的数据变换/整数操作；
中间数据使用共享RF或SRAM，通过XBAR/流FIFO交接。CPU负责任务配置、入队和同步。
默认RF为256 B，任务队列4/4/4。具体任务数、寄存器字段和参数布局以当前生成器及镜像元数据为准。

当前RF 1R1W记录的推理为 **21,008周期/张**，不含JTAG下载；十张输入逐层一致。
该端口改动改善了并行读写微基准，但没有自动改变MNIST调度周期，见[验证报告](../docs/rf1r1w.md)。

## 验证与重新生成

从仓库根目录执行，使用新tag：

```sh
python3.12 npu/scripts/run_vcs.py --suite latency --tag mnist_latency
python3.12 npu/scripts/run_vcs.py --suite jtag --tag mnist_jtag
```

在模型/参数已准备好时，`python3.12 npu/mnist/firmware.py`重新生成固件；这会改写默认artifacts。
做对照实验时先复制整个artifacts目录，再通过`NPU_ARTIFACTS_DIR`指定副本，并让仿真`--artifacts-dir`指向同一目录。
`NPU_SHARED_QUANT=0`可选择通用Vector后处理对照，不能把其周期当作默认QT01路径。
不要混用历史ABI固件、参数和当前RTL。

JTAG上板加载说明见[EGo1教程](../fpga/ego1/README.md)。旧`stream_firmware.py`与历史DMA记录不作为现行运行入口。
