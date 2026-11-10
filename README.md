# mynpu：独立 CNN／matrix／通用 vector

## 当前版本：独立计算单元与软件任务调度（2026-11-10）

CPU/JTAG SBA、两块8KB SRAM、软件管理的256B RF和XBAR连接独立的Matrix 4×4外积、CNN 3×3 DOT9及Vector INT32/4路INT8 SIMD计算单元。Matrix/Vector/CNN任务队列各4项，4条流FIFO各8 words；无独立外部DMA、无透明SRAM缓存。默认配置见[npu/build_config.json](npu/build_config.json)。

- [通用软件任务层](npu/docs/general-workloads.md)与[LY01布局 / EV01依赖事件](npu/docs/layout-events.md)：GEMM、步长/广播、归约、卷积组合，运行时配置由软件负责。
- [4/4/4版本验证](npu/docs/area26-all4.md)：综合cell面积2.569744mm²，包含两块SRAM，不含PAD/CTS/布线。
- [1950µm完整后端与Lab 5报告](npu/docs/die1950-signoff.md)：Die 1950×1950µm、Seal Ring外框1980×1980µm；PNR核心非filler面积2.633317mm²，50MHz setup/hold裕量+0.592/+0.019ns。Innovus DRC 0，最终Calibre DRC课程四类排除后0，LVS在3.48% PR教学容差下CORRECT，天线/WB均0；ERC原库/外圈残项及严格PR参数差异保留待评审，不表示正式投片签核通过。

以下为历史迭代记录，其中的“当前”、面积、周期、位宽和队列配置只适用于相应历史版本；最新配置以上述入口和源码为准。

当前已[删除透明SRAM读缓存](npu/docs/no-sram-cache.md)，由软件显式管理RF暂存。11组回归通过，10张MNIST仍为29,817周期；SRAM缓存能力报告为零。最新综合总面积 **2.438904mm²**（含两块SRAM、不含PAD），比带缓存版减少4.11%；XBAR **0.417720mm²**。
删除SRAM缓存前的[XBAR仲裁精简](npu/docs/arbitration.md)：总Cell Area **2.543393mm²**（含两块SRAM、不含PAD），XBAR **0.522962mm²**；相对上一32位Vector版总面积减少9.44%、XBAR减少33.10%。13组回归通过，MNIST仍为29,817周期。
仲裁精简前的32位Vector版[综合面积](npu/docs/vector32-area.md)：总Cell Area **2.808663mm²**（含两块SRAM、不含PAD），Vector计算与供数 **0.207111mm²**；与宽Vector版相比总面积下降3.57%、Vector下降32.98%。
当前Vector已改为[纯32位VPG2](npu/docs/vector32.md)：4×32位寄存器、通用高低半积/进位/双字移位，无64位数据通路和组合指令合并。9组回归通过，MNIST为 **29,817周期/张**；旧VPG1固件需重新生成，之前的面积报告为历史版本。
此前并行版本MNIST宏模型实测 **22,219周期/张**（原25,930，降低14.31%），12组回归通过。已加入[Matrix/Vector并行供数与计算](npu/docs/shared-parallel-operands.md)：共享RF gather、Matrix打包点积并行、Vector第二轻量lane，以及空流FIFO直接转发。下方恢复版本的25,930周期记录作为历史基线保留。
此前恢复的并行供数基线：36B循环窗口、双缓冲权重、RF gather和独立RF写回。实际SRAM宏仿真10张MNIST均为 **25,930周期/张**，JTAG 42项检查通过；队列仍为8/8/8。[恢复验证记录](npu/reports/restore_parallel_validation.json)。52,978/50,234周期的串行与轻量预取方案已撤回，旧报告仅保留实验记录。


RTL现按职责分目录，见[RTL文件导航](npu/rtl/README.md)；项目源文件统一维护在`npu/rtl/files.f`。

当前计算任务队列已统一为 **Matrix / Vector / CNN = 8 / 8 / 8**；xbar数据流FIFO仍为每通道16words。此前2.694412mm²综合结果对应8/8/16任务队列，不能当作新配置PPA。详见[架构说明](npu/docs/xbar-stream-routes.md)。

当前已实现[通用xbar流转发](npu/docs/xbar-stream-routes.md)：CNN、Matrix、Vector任意方向可通过流端点直接传数，8/8/8配置单图25,930周期；下方RF串行交接描述为历史版本。

当前改为[统一xbar与共享RF交接](npu/docs/unified-xbar.md)：CNN和Vector无直连，固件需更新；下文旧流水性能和后端结果均为历史快照。

当前已[删除独立DMA](npu/docs/jtag-only.md)，采用JTAG装载，保留计算侧Stream/Issue。下文历史后端结果为删除前快照，当前PPA待重测。

当前工程为 `mynpu-softpe`，分支 `experiment/independent-units`。保留CPU、DM/JTAG/SBA、三路DMA、2×8KB SRAM、每bank16words透明读缓存，以及256B双bank共享数据regfile；matrix/vector/CNN任务队列为8/8/16项。[默认配置](npu/build_config.json)由固件、仿真和综合共同使用。

已删除专用 `vector post` 和硬件 REQUANT。vector通过MMIO配置最多16条通用指令，使用4个64bit临时寄存器。MNIST后处理由软件组合 `LD32 → MADD32 → RSHR64 → ADD32 → MAX32 → MIN32`，U8打包只是输出格式。CNN只执行卷积并产生原始INT32，FC交给现有Matrix；CPU安排任务和依赖，NoC保持移除。

本轮已完成[CNN窗口预取与共享RF并行搬运](npu/docs/window-prefetch.md)：三字循环窗口、读返回直通、RF权重暂存和独立RF写回入口。共享RF仍256B、纯计算核源码不变。实测单图 **25,388周期**，比29,206减少 **13.07%**；CNN输入等待10,967→6,774周期。18项RTL回归、实际SRAM宏模型完整推理及权重暂存对照通过。见[本轮报告](npu/reports/window_prefetch_validation.json)。仍未达到小于20k。最新[完整含PAD后端](npu/docs/window-prefetch-pnr.md)已完成：2×2mm²，核心非filler面积2.738033mm²，50MHz下setup +0.352ns、hold +0.031ns；IO电源轨提示另行保留。

以下为纯计算核拆分阶段的基线：

上一轮完成[CNN／Matrix／Vector 三个纯计算核拆分](npu/docs/pure-compute.md)：计算核只处理操作数和算术结果，地址、循环、程序发射与存储读写由外部任务层承担。固件和整数结果不变，单图仍为29,206周期；17项RTL回归及实际SRAM宏模型下的完整推理通过。逐层计数显示，CNN输入窗口等待10,967周期，FC整体7,029周期，Vector主要与CNN重叠且等待输入。见[本轮验证与周期报告](npu/reports/pure_compute_validation.json)。本轮未重新测量面积时序。

以下为2026-11-04 CNN精简阶段的历史综合结果：

上一轮实现[CNN最小计算核](npu/docs/minimal-compute.md)：CNN只保留9路乘法、INT32累加及ready/valid，删除私有部分和数组与结果FIFO。搬运使用16×32bit任务，软件预生成边界mask；公共配置按层复用，部分和放现有共享RF。完整MNIST已通过，当前29,206推理周期，慢于上一版25,156，仍未达到小于20k目标。最终全核心综合面积 **2.666814mm²**（含两块SRAM、不含PAD），比上一版减少 **7.57%**；50MHz综合setup **+4.0036ns**。16项RTL与4项无SDF映射网表回归全部通过，详见[本轮报告](npu/reports/minimal_compute_validation.json)。本轮未重跑布局布线。

以下为RF-gather基线：

上一版实现[共享RF并行读与CNN小窗口](npu/docs/rf-gather.md)：256B容量不变，8个物理bank，计算侧3×32bit独立地址读取。CNN输入payload从168B缩至24B，实测推理25,156周期（比上一版减少794周期），仍未达到小于20k目标。全核心综合面积2.885133mm²（含两块SRAM、不含PAD），50MHz综合setup +4.0007ns；总面积比上一版增加约0.13%，未实现面积压缩。15项RTL与4项无SDF映射网表回归通过。新结果见[本轮报告](npu/reports/rf_gather_validation.json)。

以下为上一轮基线：

当前已完成[CNN卷积专用化与FC迁移](npu/docs/cnn-conv-only.md)：默认256B RF综合面积2.881318mm²（含两块SRAM、不含PAD），CNN合计0.500113mm²；50MHz综合setup +4.0077ns。推理25,950周期，15项RTL与4项无SDF映射网表回归通过，但超过原小于20k目标。新的综合结果见[本次报告](npu/reports/cnn_conv_only_validation.json)。

下面的容量对照和含PAD后端属于**删除CNN FC之前的历史基线**，不能代表当前版本。

| 删除CNN FC前配置 | RF容量 | 综合Cell Area，不含PAD | 50MHz综合setup slack | 推理周期 | 仿真含输入DMA |
|---|---:|---:|---:|---:|---:|
| 默认 | 256B | **2.927683mm²** | **+4.0061ns** | **19,986** | 20,607 |
| 对照 | 512B | 3.063293mm² | +4.0028ns | 18,711 | 19,332 |

两种配置均通过15项RTL回归和4项无SDF映射网表回归，十张样本逐层整数结果一致。默认配置因512B版本超出3mm²综合面积预算而选为256B；含输入DMA及连续流平均周期不能等同于纯推理周期。9 PAD封装通过JTAG SBA加载数据，JTAG传输时间另计。

[通用vector设计与指令编码](npu/docs/vector-program.md) · [删除CNN FC前报告](npu/reports/vector_program_validation.json) · [EDA复现](npu/eda/tsmc180/README.md) · [MNIST软件](npu/mnist/README.md)

删除CNN FC前的256B RF已试跑含9信号PAD的2mm×2mm后端：放置密度98.02%，CTS后重新合法化仍有9个标准单元重叠，停止详细布线，50MHz尚未收敛。见[本次后端记录](npu/docs/vector-program-pnr.md)及[机器报告](npu/reports/fullchip_vector_program_validation.json)。此前512B专用路径的2mm×2mm含PAD后端有124处DRC、setup −0.566ns、hold −0.033ns，作为[历史物理记录](npu/reports/fullchip_logic_trim_validation.json)保留，不能代表本轮RTL。更早的[逻辑精简记录](npu/reports/logic_trim_validation.json)和[容量对照](npu/reports/logic_trim_rf32_validation.json)同样属于历史版本。

格式规范见[FORMATTING.md](FORMATTING.md)：`make format` / `make format-check`。
