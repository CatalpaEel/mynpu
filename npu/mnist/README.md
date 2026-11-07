# SD91：窗口预取与RF权重暂存的MNIST软件

当前已[删除透明SRAM读缓存](../docs/no-sram-cache.md)，由软件显式管理RF暂存。11组回归通过，10张MNIST仍为29,817周期；SRAM缓存能力报告为零。最新综合总面积 **2.438904mm²**（含两块SRAM、不含PAD），比带缓存版减少4.11%；XBAR **0.417720mm²**。
删除SRAM缓存前的[XBAR仲裁精简](../docs/arbitration.md)：总Cell Area **2.543393mm²**（含两块SRAM、不含PAD），XBAR **0.522962mm²**；相对上一32位Vector版总面积减少9.44%、XBAR减少33.10%。13组回归通过，MNIST仍为29,817周期。
仲裁精简前的32位Vector版[综合面积](../docs/vector32-area.md)：总Cell Area **2.808663mm²**（含两块SRAM、不含PAD），Vector计算与供数 **0.207111mm²**；与宽Vector版相比总面积下降3.57%、Vector下降32.98%。
当前Vector已改为[纯32位VPG2](../docs/vector32.md)：4×32位寄存器、通用高低半积/进位/双字移位，无64位数据通路和组合指令合并。9组回归通过，MNIST为 **29,817周期/张**；旧VPG1固件需重新生成，之前的面积报告为历史版本。
此前并行版本MNIST宏模型实测 **22,219周期/张**（原25,930，降低14.31%），12组回归通过。已加入[Matrix/Vector并行供数与计算](../docs/shared-parallel-operands.md)：共享RF gather、Matrix打包点积并行、Vector第二轻量lane，以及空流FIFO直接转发。下方恢复版本的25,930周期记录作为历史基线保留。
此前恢复的并行供数基线：36B循环窗口、双缓冲权重、RF gather和独立RF写回。实际SRAM宏仿真10张MNIST均为 **25,930周期/张**，JTAG 42项检查通过；队列仍为8/8/8。[恢复验证记录](../reports/restore_parallel_validation.json)。52,978/50,234周期的串行与轻量预取方案已撤回，旧报告仅保留实验记录。


当前已实现[通用xbar流转发](../docs/xbar-stream-routes.md)：CNN、Matrix、Vector任意方向可通过流端点直接传数，8/8/8配置单图25,930周期；下方RF串行交接描述为历史版本。

当前改为[统一xbar与共享RF交接](../docs/unified-xbar.md)：CNN和Vector无直连，固件需更新；下文旧流水性能和后端结果均为历史快照。

最新[完整含PAD后端结果](../docs/window-prefetch-pnr.md)：2×2mm²，核心非filler面积2.738033mm²，TT 50MHz的setup/hold均收敛；原生IO电源轨的两条工具提示单独保留。

当前加入[循环窗口预取与RF并行搬运](../docs/window-prefetch.md)。算术核保持纯计算，CPU仍向外部任务层提交32bit命令。五层卷积共296个tile任务，FC为90个Matrix K16任务，Vector用通用指令完成后处理。

第一、二层输入和输出均在SRAM，软件在任务提交前把整层权重暂存在空闲RF：分别20B（按word补齐）和72B。末尾32B仍留作部分和工作区；其余层根据容量与张量活跃区间跳过暂存。Stream从RF gather口读权重、从普通口读SRAM激活，并通过独立RF入口写部分和。

程序像仍4608B，入口`0x80000080`，描述表在`0x80000c00`，任务表在`0x80000d50..0x800011ef`。单图711条CPU指令，连续流724条。参数仍4052B；原权重、输入及逐层整数golden未变。

实测十张单图均 **25,388周期**，含输入DMA **26,009周期**；20帧连续流516,512周期，平均25,825.6周期。关闭RF权重暂存的对照为25,605周期，暂存净省217周期，已计入复制成本。相比29,206周期基线，总周期减少13.07%，仍未达到小于20k。见[本轮报告](../reports/window_prefetch_validation.json)。

```sh
python3.12 npu/mnist/firmware.py
python3.12 npu/mnist/stream_firmware.py
python3.12 npu/scripts/run_vcs.py --suite rfsink --tag NEW_SINK
python3.12 npu/scripts/run_vcs.py --suite layers --tag NEW_LAYERS
python3.12 npu/scripts/run_vcs.py --suite latency --tag NEW_LATENCY
python3.12 npu/scripts/run_vcs.py --suite stream --tag NEW_STREAM
```

18项RTL及实际SRAM宏模型完整推理通过。功能报告与后端报告分开记录，物理结果见上方最新链接。SD91接口保持兼容，`NPU_RF_WEIGHT_CACHE=0`可为独立artifacts副本生成不暂存权重的对照固件。

下面保留CRW2软件与性能记录作为历史基线，不代表当前固件。

> 当前硬件已加入[RF并行读与CNN小窗口](../docs/rf-gather.md)，原固件和参数不变。单图25,156周期，仿真含输入DMA25,777周期；20帧连续流509,731周期。本页后续25,950周期和原综合数据是改造前基线。

# 卷积由CNN、FC由Matrix执行MNIST

当前CNN只执行卷积，ABI为CRW2。五层卷积共212个行任务；144→10的FC层由Matrix执行90个K16分块任务，随后用通用Vector指令补偿零点和后处理。详见[设计、整数公式与软件调度](../docs/cnn-conv-only.md)及[本次验证报告](../reports/cnn_conv_only_validation.json)。

原checkpoint、唯一权重副本、UINT8输入和逐层golden不变，没有重训。参数区在bank1 `0x80002000`，原3932B参数后追加120B软件生成的FC常量，共4052B。代码位于bank0，入口`0x80000080`，描述表`0x80000c00`，程序像含填充4KB；单图681条CPU指令，连续流694条。

默认RF为两bank各32×32bit，共256B。最后一层输入可原地重编码为signed INT8，Matrix原始结果放共享RF空闲尾部。Vector以INT64计算补偿偏置，保留原有Q24舍入和U8裁剪；卷积仍使用CNN→Vector流式重叠。过大张量仍暂存SRAM，未新增im2col或复制权重矩阵。

实测10张单图均为 **25,950推理周期**，仿真含输入DMA26,571周期；20帧连续流525,780周期，平均26,289周期。15项RTL与4项无SDF映射网表回归通过，但目前超过原来的小于20k周期目标，瓶颈转到通用Matrix的逐项取数与小K任务调度。9 PAD封装的数据通过JTAG SBA装载，JTAG传输时间另计。

```sh
python3.12 npu/mnist/firmware.py
python3.12 npu/mnist/stream_firmware.py
python3.12 npu/scripts/run_vcs.py --suite layers --tag NEW_TAG
python3.12 npu/scripts/run_vcs.py --suite latency --tag NEW_LATENCY
python3.12 npu/scripts/run_vcs.py --suite stream --tag NEW_STREAM
```

生成其他RF配置时，复制artifacts到独立目录，同时设置`NPU_RF_BANK_WORDS`与`NPU_ARTIFACTS_DIR`；仿真对应使用`--rf-bank-words`及`--artifacts-dir`。旧CRW1/CRO2或REQUANT固件不能继续使用，启动代码检查CRW2、VPG1与RF容量。历史19,986周期和旧含PAD后端结果不能代表当前RTL/固件。
