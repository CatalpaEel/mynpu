> 本地集成说明（2026-11-14）：开发代码已合入无GPIO、无Host的JTAG-only主线。`versions/ego1-10mhz-20261114`是旧`afb74fd`硬件/板测的冻结归档，其旧Host端口只存在于归档源码，不参与当前编译；不能将归档镜像当成合并后设计的bitstream。
> 当前服务器已安装Vivado 2025.2，推荐用`~/tools/bin/vivado`兼容启动器；下面历史板测使用Vivado 2023.2。新的合并验证见[集成报告](MERGE-20261114.md)。

# EGo1 板级 Vivado 工程

已发布上板分支：`fpga/ego1-board-20261114-afb74fd`。
**本次实板验证的固定版本见 [ego1-10mhz-20261114](versions/ego1-10mhz-20261114/README.md)**，
包含实际构建的源码快照、bit/MCS、配套输入/程序和原始测试记录。
SoC 基线为 `afb74fd`，冻结硬件源码对应 `03e2870`；不代表后续 `main` 已通过本次板测。

原本地工作分支 `fpga/ego1-asic-validation` 的连续推理、重载和 ASIC/FPGA 双后端测试见
[上板验证操作说明](VALIDATION.md)。原板测环境的Vivado 2023.2已实际执行完整SoC构建。原始RTL默认50MHz优化后25,077 LUT，
中等面积策略在25MHz和10MHz下均为22,431 LUT，超出XC7A35T的20,800 LUT。
10MHz FPGA专用CPU寄存器堆和CNN DSP映射已经生成可下载镜像，板测包见VALIDATION.md。
本分支构建默认25MHz，通过实际MMCM分频实现，可选择10/25/50MHz；芯片共用RTL保持原样。

沿用此前 EGo1 V2.2，器件 **XC7A35T-CSG324-1**，100MHz输入经MMCM生成系统时钟，构建默认25MHz，可选10/25/50MHz。
本目录接入当前独立 Matrix/CNN/Vector、256 B RF、4/4/4 任务队列和两块 8 KiB SRAM。
没有恢复旧版 torus、NoC 或外部 DMA。SRAM 为同步读、字节写使能的可推断 BRAM，是否实际映射为 RAMB 以综合报告为准。

## 当前完成状态

已补齐板级顶层、引脚/时钟约束、独立 Vivado 构建入口、可移植源码快照及外部 JTAG 加载脚本。
板级功能仿真使用真实 CPU/DTM/DM，通过引脚装载完整 MNIST 镜像并比较十个整数输出；额外检查复位、时钟和 LED。
MMCM/BUFG 在 VCS 中使用功能替身，不代表真实 FPGA 时序或硬件测试。

本次合并验证使用新的JTAG-only源码：FPGA 10MHz＋CPU LUTRAM和ASIC 50MHz＋真实SRAM宏，分别做两次启动、20帧推理；具体检查数及版本哈希见[集成报告](MERGE-20261114.md)。Vivado 2025.2的RTL展开通过，不等于资源映射或布局布线通过。

旧冻结10MHz版本已完成布局布线，实体板100kHz JTAG通过2021次推理，使用PC访问前halt/之后resume的流程。它的资源数据与失败记录仍见`ego1_validation_preparation.json`，不将该镜像/时序结果归给当前合并代码。

## 构建到上板前

从仓库根目录执行，建议使用此前板卡使用过的 Vivado 2023.2；2025.2 也可尝试，但应记录实际工具版本。
无需旧 `xc7a35t.xpr`、板卡数据库或绝对路径工程。旧版本已用2023.2实际执行；当前合并代码已通过2025.2 RTL展开，完整综合/实现尚未执行。

```sh
# 已将 Vivado 加入 PATH 时
python3 npu/fpga/ego1/build.py --out npu/build/ego1-run1
# 或指定可执行文件
python3 npu/fpga/ego1/build.py --out npu/build/ego1-run1 --vivado /path/to/Vivado/bin/vivado
# 原入口现在也执行板级流程
PYTHON=python3.12 bash npu/scripts/build_vivado.sh --out npu/build/ego1-run1
```

没有 Vivado 的服务器先准备快照：

```sh
python3.12 npu/fpga/ego1/build.py --prepare-only --out npu/build/ego1-portable
```

将整个输出目录复制到安装 Vivado 的机器；进入该目录，执行：

```tcl
# Vivado Tcl Console
source build.tcl
```

也可从该目录运行 `vivado -mode batch -source build.tcl`。
快照包含 RTL、CPU 头文件、构建参数、XDC、SHA256 清单，不依赖服务器路径。
GUI 中打开输出目录下 `project/ego1_mynpu.xpr`，在 Synthesis/Implementation 的 Open Synthesized/Implemented Design
中查看层次利用率、时钟、时序路径和布线。修改设计后应创建新的快照目录，避免覆盖原证据。

流程执行完整板级综合 → 布局布线 → 报告 → setup/hold 与 DRC 检查 → bitstream → SPIx4 MCS。
不降级 UCIO/NSTD 等检查，也不连接 Hardware Manager 或烧写实体板卡。
完成时输出：

| 文件 | 用途 |
| --- | --- |
| `ego1_mynpu.bit` | 板卡易失性 FPGA 配置 |
| `ego1_mynpu.mcs` | 8 MiB SPI Flash 配置镜像，沿用旧板 N25Q64 容量 |
| `ego1_routed.dcp` | 布局布线检查点 |
| `reports/*.rpt` | 综合/实现层次资源、时序、CDC、时钟关系、DRC、布线状态 |
| `implementation_pass.txt` | 实际 Vivado 版本和最差 setup/hold slack；成功才生成 |
| `source_manifest.json` | 冻结输入的 SHA256 与配置 |

上板前应确认完整布线、无未约束内部时序路径、setup/hold 均非负、无阻断 DRC，并人工审阅 CDC/方法学报告。
任何 Vivado 失败都应先处理，不能把源码准备成功当作 bitstream 成功。
旧 `npu/scripts/build_vivado.tcl` 保留为历史 OOC 脚本，不是当前板级入口。

## 引脚和板上观察

| 信号 | 板卡引脚 | 说明 |
| --- | --- | --- |
| 100 MHz | P17 | 输入时钟 |
| RESET | P15 | 低有效；异步置位复位、同步释放 |
| TCK / TDI / TDO / TMS | E15 / E16 / D15 / C15 | J5 外接 FT232H；与 FPGA 配置 JTAG 独立 |
| LED0…7 | K3 / M1 / L1 / K6 / J5 / H5 / H6 / K1 | 高有效 |

LED0=MMCM locked，LED1=心跳，LED2=任意 NPU IRQ，LED3=CPU halted，LED4=TCK 活动，
LED5=软件测试完成，LED6=测试成功，LED7=0。此处 LED4 是活动指示，不用于协议控制。
RESET 为板级 POR；Debug Module 的 ndmreset 不重新锁定 MMCM。
所有外部信号沿用 LVCMOS33。TCK 按最高 1 MHz 约束，实际连接先使用 10 kHz。

## JTAG 推理

已实板验证的入口是版本目录内的 `npu/fpga/ego1/jtag_validation.py`，操作见版本说明。
下面的旧 `load_mnist.tcl` 入口未参与本次2021帧板测，不等同于已验证的暂停/恢复流程。

板卡经原配置 JTAG 下载 `.bit` 后，CPU 在 bootstrap WFI 等待；没有把 MNIST 程序固化进 BRAM。
FT232H 的 AD0/1/2/3 分别接 TCK/TDI/TDO/TMS，接公共 GND，沿用旧板接线。
从仓库根目录运行：

```sh
openocd -f npu/fpga/ego1/ft232h.cfg -f npu/debug/target.cfg -f npu/fpga/ego1/load_mnist.tcl
```

脚本复位 CPU → halt → SBA 加载并校验 16 KiB 镜像 → 设置入口 `0x80000080` → 启动/恢复 →
轮询 `0x40000004` 测试结果 → 对比 `0x80001400` 的十个 INT8 logits。
使用当前 `npu/mnist/artifacts/sram0.bin` 和 `gold0_5.hex`；此脚本尚未在本版实体板验证。
`.mcs` 仅包含 FPGA 配置，Flash 启动后仍需通过 JTAG 下载程序/数据。

## 不连接板卡的回归

```sh
python3.12 npu/fpga/ego1/simulate.py --out npu/build/ego1-test1
```

复用已有完整芯片 JTAG 测试，替换为真实板级 wrapper；结果及输入哈希在输出目录 `validation.json`，
日志见 `compile.log`、`sim.log`。这里只用模拟时钟原语，Vivado 源码快照不包含这些替身。
