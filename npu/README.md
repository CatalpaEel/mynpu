# 当前架构入口

当前[配置时序由软件负责](docs/software-owned-config.md)：取消 CNN / Vector 程序 / QT01 的忙时与排空写保护，Matrix 保持任务快照；无双缓冲或新增暂停机制。Operator ABI 2.2，15 组回归通过，默认共享量化仍为 23,937 周期/图，当前 PPA 未重测。

当前 CNN 使用 [SD95 count1～16](docs/count16.md)：[3:0] 为 count−1，没有配置选择位，保持单套配置和 32bit FIFO。默认共享 QT01 为 23,937 周期/图，CNN 任务 296→212；RF 仍为 256B，当前 PPA 未重测。

最新 CNN 使用 [SD94 count−1 编码](docs/count-minus-one.md)：数量占 [2:0]，bit3 保留为 0，FIFO 仍为 32bit。默认共享 QT01，旧固件需重生成。

生产固件现已[默认共享 QT01 量化](docs/quant-default.md)，未设置环境变量即可生成共享量化镜像，当前 26,067 周期/图。下文 Vector 后处理的“默认”称呼属于此前版本；硬件配置排空保护目前仍保留。

当前采用[SD93 / Matrix 4 / VPG3](docs/command-layout.md)：CNN 输入与卷积核共享、32bit 窗口任务；Matrix 精度与存储间距独立、lda/ldb 随任务快照，流模式支持完整 4×4；字节码字段重新排序。20 组回归通过，默认/共享量化为 30,835 / 26,067 周期/图；旧固件需重生成，当前 PPA 未重测。

最新 CNN 已改为[显式卷积核地址 SD92](docs/cnn-kernel-address.md)：地址随任务进入 43bit FIFO，删除 co 寻址；旧固件需重生成，默认镜像已更新。13 组回归通过，默认/共享量化为 29,297 / 26,061 周期/图，尚未重测 PPA。

已[扩大单次任务规模](docs/task-scale.md)：Matrix K≤256、Vector≤4096 元素、CNN 输入通道≤256，保留原有计算阵列与缓存；九组回归通过，尚未重测 PPA。


当前已[拆分Matrix/Vector/CNN为IRQ16/17/18](docs/irq-independent.md)，完成与错误均可唤醒WFI，支持运行中确认done及同拍新事件优先。默认固件已重生成，旧WFI镜像需要更新。共享QT01为25,965周期/张，通用Vector为29,298周期/张。本轮RTL有改动，以下旧面积/时序测量不能代表当前IRQ版本，尚未重测PPA。

共享量化固件已加入[完成中断＋WFI等待](docs/irq-wfi-wait.md)：MNIST **27,432 → 26,092周期/张**，减少4.88%；CPU取指造成的CNN同bank等待4,424 → 2,490拍。RTL/面积不变；通用Vector固件二进制不变。以下周期统计请按报告版本区分。

已补充[18ns＋门控的面积归属与软件阻塞分布](docs/area18-distribution-and-blocking.md)：最终网表leaf级面积统计、两条软件路径各10张图的CPU/轮询/逐层等待分析及三张图。RTL与固件未为统计改动。

最新[面积压缩结果](docs/area25-optimization.md)：**2.515488mm²**（含两块SRAM、不含PAD），相比2.846849mm²减少 **11.64%**。采用high综合、自动门控与18ns再优化；50MHz setup slack **+2.0040ns**。全部功能、256B RF和8/8/8队列保留，推理周期不变；未重跑PNR，严格2.5mm²还差0.015488mm²。

此前完成[Matrix、CNN、Vector Stream精简](docs/streams-optimized.md)：递增寻址、CNN行窗口选择共享、Vector缓冲与地址ALU复用。21组验证通过，默认/共享量化/旧固件分别为29,173 / 27,432 / 30,710周期，均与本轮优化前一致。[最新综合面积与时序](docs/streams-optimized-area.md)：总面积 **2.846849mm²**（含两块SRAM，不含PAD），50MHz setup slack **+4.0020ns**，本轮未跑PNR。下列数值为各历史版本。

当前Matrix已改为[4×4外积、16个INT32累加器](docs/matrix-outer4.md)；支持INT8/INT16、转置、尾块及可选量化。旧2.586795mm²综合数据属于点积版；[Stream精简前综合](docs/matrix-outer4-area.md)总面积 **2.976653mm²**（含SRAM、不含PAD），50MHz setup slack **+4.0012ns**，未重跑布局布线。

[旧点积Matrix版QT01综合](docs/shared-quant-area.md)：总面积 **2.586795mm²**（含两块SRAM、不含PAD），比量化前同配置增加6.20%；50MHz综合setup slack **+4.0014ns**。未重跑布局布线。

新增[CNN / Matrix 直连的共享可选量化单元 QT01](docs/shared-quant.md)：默认原始 INT32 旁路，可选量化后32位或字节写回。MNIST实验固件实测27,633周期/张；旧固件仍29,817周期。

当前Vector已改为[单ALU：INT32 / 4×INT8 SIMD](docs/vector-simd.md)，删除独立轻量ALU。以下含旧版本测量，请按各报告对应源码版本区分。

当前已[删除透明SRAM读缓存](docs/no-sram-cache.md)，由软件显式管理RF暂存。11组回归通过，10张MNIST仍为29,817周期；SRAM缓存能力报告为零。最新综合总面积 **2.438904mm²**（含两块SRAM、不含PAD），比带缓存版减少4.11%；XBAR **0.417720mm²**。
删除SRAM缓存前的[XBAR仲裁精简](docs/arbitration.md)：总Cell Area **2.543393mm²**（含两块SRAM、不含PAD），XBAR **0.522962mm²**；相对上一32位Vector版总面积减少9.44%、XBAR减少33.10%。13组回归通过，MNIST仍为29,817周期。
仲裁精简前的32位Vector版[综合面积](docs/vector32-area.md)：总Cell Area **2.808663mm²**（含两块SRAM、不含PAD），Vector计算与供数 **0.207111mm²**；与宽Vector版相比总面积下降3.57%、Vector下降32.98%。
当前Vector已改为[纯32位VPG2](docs/vector32.md)：4×32位寄存器、通用高低半积/进位/双字移位，无64位数据通路和组合指令合并。9组回归通过，MNIST为 **29,817周期/张**；旧VPG1固件需重新生成，之前的面积报告为历史版本。
此前并行版本MNIST宏模型实测 **22,219周期/张**（原25,930，降低14.31%），12组回归通过。已加入[Matrix/Vector并行供数与计算](docs/shared-parallel-operands.md)：共享RF gather、Matrix打包点积并行、Vector第二轻量lane，以及空流FIFO直接转发。下方恢复版本的25,930周期记录作为历史基线保留。
此前恢复的并行供数基线：36B循环窗口、双缓冲权重、RF gather和独立RF写回。实际SRAM宏仿真10张MNIST均为 **25,930周期/张**，JTAG 42项检查通过；队列仍为8/8/8。[恢复验证记录](reports/restore_parallel_validation.json)。52,978/50,234周期的串行与轻量预取方案已撤回，旧报告仅保留实验记录。


RTL现按职责分目录，见[RTL文件导航](rtl/README.md)；项目源文件统一维护在`npu/rtl/files.f`。

当前计算任务队列已统一为 **Matrix / Vector / CNN = 8 / 8 / 8**；xbar数据流FIFO仍为每通道16words。此前2.694412mm²综合结果对应8/8/16任务队列，不能当作新配置PPA。详见[架构说明](docs/xbar-stream-routes.md)。

当前已实现[通用xbar流转发](docs/xbar-stream-routes.md)：CNN、Matrix、Vector任意方向可通过流端点直接传数，8/8/8配置单图25,930周期；下方RF串行交接描述为历史版本。

当前改为[统一xbar与共享RF交接](docs/unified-xbar.md)：CNN和Vector无直连，固件需更新；下文旧流水性能和后端结果均为历史快照。

当前已[删除独立DMA](docs/jtag-only.md)，采用JTAG装载，保留计算侧Stream/Issue。下文历史后端结果为删除前快照，当前PPA待重测。

最新[完整含PAD后端结果](docs/window-prefetch-pnr.md)：2×2mm²，核心非filler面积2.738033mm²，TT 50MHz的setup/hold均收敛；原生IO电源轨的两条工具提示单独保留。

CNN、Matrix、Vector都是纯计算模块；外部Stream/Issue管理地址、循环、程序发射与访存应答。当前加入[循环窗口预取与共享RF并行搬运](docs/window-prefetch.md)，完整结构见[纯计算核说明](docs/pure-compute.md)。

- 纯运算：[CNN](rtl/cnn/npu_cnn.sv)、[Matrix](rtl/matrix/npu_matmul.sv)、[Vector](rtl/vector/npu_vector.sv)，本轮算术源码未修改，没有专用量化核。
- 供数/发射：[CNN Stream](rtl/cnn/npu_stream.sv)、[Matrix Stream](rtl/matrix/npu_matrix_stream.sv)、[Vector Stream](rtl/vector/npu_vector_stream.sv)。CNN每行3个word的循环窗口支持预取和回复直通；RF写回可以与普通SRAM读、gather读重叠。
- 存储：[XBAR](rtl/interconnect/xbar.sv)、[共享RF](rtl/interconnect/npu_data_regfile.sv)、2×8KB SRAM与每bank16words透明SRAM读缓存。RF仍256B、8个物理bank，3×32bit gather读；专用RF写回入口复用已有bank单端口与仲裁。
- 软件：[单图固件](mnist/firmware.py)、[连续流固件](mnist/stream_firmware.py)。第一、二层暂存20B/72B权重，其余层按活跃区间保留原存储方式；原模型、参数、输入与整数golden不变。
- 配置：[build_config.json](build_config.json)，默认RF两段各32words，Matrix/Vector/Stream FIFO=8/8/16。仿真、源列表与固件读取同一配置。

SD91和VPG1接口不变，启动检查ABI与RF容量。Vector先排入消费任务，再提交匹配的CNN tile；每层两侧完成后才复用RF。Matrix/CNN普通master 1仍相互排斥；新增RF写回入口不表示两种任务已能同时执行。

当前单图 **25,388周期**，含输入DMA **26,009周期**；20帧连续流516,512周期，平均25,825.6周期。18项RTL与实际SRAM宏模型推理通过，见[本轮验证报告](reports/window_prefetch_validation.json)。相比纯计算核拆分基线，周期减少13.07%，但未达到小于20k。

`run_vcs.py`支持18项回归：rfsink、purecompute、cnncompute、regfile、cnnqueues、ops、jtag、soc、nmc、nmcconcurrent、dma、queues、burst、enginefaults、vectorprogram、latency、layers、stream。SoC相关套件可选实际SRAM宏模型。

本轮没有新的综合或布局布线测量。此前2.666814mm² / 50MHz setup +4.0036ns属于CNN精简阶段的[历史报告](reports/minimal_compute_validation.json)，不能代表当前RTL。EDA流程见[说明](eda/tsmc180/README.md)，更早的含PAD试跑同样只代表其冻结版本。
