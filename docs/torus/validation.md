# ABI 4 面积优化验证

2026-10-29，`mynpu-torus` 工作区。用户接受约 20233 周期后，默认选择每流端口 32-word cache，优化目标为减少面积，同时维持这一周期水平。旧的 64-word、严格小于 20k 记录保留在 [ABI 3 验证](validation-v3.md)。

## 实现与功能边界

保留 4×4 torus、每 PE 四个本地 32bit 寄存器、两路独立邻居读、仅本地算术写、两个共享 8KB 单端口 SRAM、唯一参数副本、CPU SRAM 程序与逐条 32bit MMIO 发令。PE 保留全部 opcode 0～52，包含完整 INT8/INT16/INT32 乘法／MAC、MULH、MULHR。量化没有移到 CPU 或外置单元。

本轮结构改动：

- cache 从每口 64 words 降为 32 words，数据容量从 512B 降为 256B。每口四个浅 bank，每 bank 一次读一个 word；同 word 广播，同 bank 不同 word 分次收集。尚未查询的 word 不作为 SRAM miss 提前发送。
- 流描述符 base、tile/outer stride 和游标为有符号 16bit，shape/index 为无符号 16bit。MMIO 布局不变，ID 升为 `0x544f5204`，`0x028` 返回位宽能力 `0x10100e10`。
- 超范围配置字段会置错并阻止传输，必须重写该字段修复；清 IRQ 不能使截断值恢复有效。游标与外轴基址加法保留溢出标志，ARM 清除游标溢出。tile 地址组合保留 19bit 检查范围，避免截断别名访问低 SRAM。
- PE 普通移位、旋转与舍入右移共用桶形移位器；舍入右移复用原加法器。CLZ／CTZ 共享计数逻辑，POPCNT 改平衡加法树。指令整数语义与旧 PE 一致。
- 综合从低 effort 快速映射改为 medium effort generic/map/opt。完整芯片结果包含 RTL 和综合策略的共同收益，不能全部算作某一个 RTL 改动的收益。

接口范围与具体编码见 [架构说明](README.md)，软件流水见 [overlap.md](overlap.md)。16bit shape 支持 1～65535，signed base/stride 支持 −32768～32767，实际 SRAM 地址仍必须在 0～16383。超范围调度由软件禁止，未减少 PE 数据精度。

## 功能和周期

单元回归：FPGA 与 ASIC 各 **4973 项通过**；新 PE 映射网表与当前 RTL 的混合仿真同样通过 4973 项。覆盖所有移位量、符号极值、整数舍入 ties、正反旋转、位计数、随机多精度乘法与 MULHR、全部邻居读／本地写、预取／bundle、跨 bank BASEPAIR、普通搬运依赖、四 bank cache 冲突收集、精确失效，以及超范围配置／游标溢出不能误访问 SRAM。

**FPGA 与 ASIC 功能后端，各 64 个样本全部通过。完整推理为 20233～20237 周期，六层到 SRAM 写回均为 20104 周期；每个后端核对全部六层的 114816 个实际输出字节，与整数 golden 全部一致。** 与旧版相同 32-word 配置的周期一致。测试台独立计时钟，和固件 mcycle 报告完全一致；本轮设置严格 `<20300` 回归上限，包含 CPU argmax。JTAG 上传、启动自测及最终完成报告不计入推理。

ASIC 单样本的六层 SRAM 快照经真实 SBA 全部读回通过，含快照复制与 argmax 为 **34686 周期**。FPGA 的 16/64-word 参数配置也各通过 4973 项单元检查。所有最终运行的 `changed_during_run` 均为空。

CPU 程序和只读表 **5604B**；包含 161 个 tile 的 1932B 元数据及 19 个边界模板的 1216B 原生指令代码槽。原始参数区 4288B，另有 32B 编译期派生 bias 表；没有复制权重。所有六层都实际写回共享 SRAM，非硬编码分类结果。

golden 使用原始模型、原始逐项零点减法和原始 M/2^31 参数。64 个样本模型语义 SHA256 为 `66322dea8f64a3606743e7cc19bc3ad8ed956684b5dd121a57295ee4503550ce`，构建时核对既有整数输出；与已记录 PyTorch 最终输出最大差 1 code。本轮没有重新运行 PyTorch，也不代表完整 MNIST 准确率测试。

## 面积与时序

| 实测对象 | Cell Area，含 SRAM | 流单元 | 50MHz 映射 setup slack |
|---|---:|---:|---:|
| ABI 3，64 words/口，低 effort 快映射 | 4.479290mm² | 1.098621mm² | +0.1349ns |
| 同旧 RTL，仅改 32 words/口，低 effort 快映射 | **4.288349mm²** | 0.851351mm² | +0.1043ns |
| ABI 4，32 words/口，medium 完整优化 | **3.320404mm²** | **0.568221mm²** | **+0.0203ns** |

完整优化后的面积较原 64-word 版本减少 **25.87%**，较只降 cache 的旧 32-word 版本减少 **22.57%**；标准单元面积为 **2.517517mm²**，两个 SRAM 宏仍为 **0.802887mm²**。PE 阵列为 **1.526582mm²**，较原 2.131515mm² 减少约 28.4%；流单元较原 1.098621mm² 减少约 48.3%。这些数字包含 medium 综合／syn_opt 收益，不应全部归因于 RTL。

只缩小 cache 的完整芯片面积减少约 4.3%；整芯片重新映射也会改变其他单元尺寸，不能把总面积差直接当作 cache 单块增量。

新独立 PE 在 medium generic/map/opt 后为 **73541.395µm²**。这是带假设 IO 延迟／负载的独立块测量，不等于放回阵列后的单 PE 面积，更不能直接相加充当整芯片面积。

当前完整运行：`eda-runs/20261029-torus-area-v4`；独立 PE：`eda-runs/20261029-torus-area-v4-pe`；仅缩 cache 的旧 RTL 对照：`eda-runs/20261029-torus-area-cache32-baseline`。全部采用相同 TSMC180 TT 标准单元／SRAM 库、20ns 系统时钟和两块 SRAM，实际库文件哈希随输入冻结。

2mm×2mm 的 Die 核心面积为约 3.027321mm²，可分配标准单元区域约 2.018759mm²；还需考虑目标密度和布线空间。ABI 4 的实际 floorplan／IO 已完成，工具报告 core utilization 为 **108.810012%**，面积仍不足以容纳当前设计。供电阶段完成。实际 placement 因 `IMPSP-190` 被拒绝：标准单元需求 **2469075µm²**，可分配区域 **2018759µm²**，利用率 **122.3%**；原 64-word 版本为 180.2%。**当前仍放不进 2mm×2mm，未进入 CTS／route，没有布线后时序结果。**最终综合的 sys_clk setup slack 为 +20.3ps、TNS=0，没有 setup 违例；裕量较薄。最终检查无 unresolved/empty module、无 undriven/multidriven leaf pin。综合估计不能代表布线后 50MHz、功耗或 signoff；宏内部 timing-check 与 PDK signoff 不在本次范围。

## 重现及证据

```bash
python3 tools/build_torus.py --out build/torus/area-v4-full --vectors 64 --corpus tests/torus/mnist_vectors_full.json --cache-words 32
python3 tools/run_torus.py --memory fpga --suite unit --cache-words 32 --tag area-v4-banked-fixed
python3 tools/run_torus.py --memory asic --suite unit --cache-words 32 --tag area-v4-banked-fixed
python3 tools/run_torus.py --memory fpga --suite soc --assets build/torus/area-v4-full --cache-words 32 --max-cycles 20300 --tag area-v4-final64
python3 tools/run_torus.py --memory asic --suite soc --assets build/torus/area-v4-full --cache-words 32 --max-cycles 20300 --tag area-v4-final64
```

- [当前资产 manifest](../../build/torus/area-v4-full/manifest.json)、[CPU ELF](../../build/torus/area-v4-full/cpu.elf)、[CPU hex](../../build/torus/area-v4-full/cpu.hex)、[逐层 golden](../../build/torus/area-v4-full/golden.hex)。
- [FPGA 单元](../../build/torus/unit-fpga-area-v4-banked-fixed/result.json)、[ASIC 单元](../../build/torus/unit-asic-area-v4-banked-fixed/result.json)、[新 PE 门级混合仿真](../../build/torus/unit-fpga-area-v4-mapped/result.json)。
- [FPGA 64 样本](../../build/torus/soc-fpga-area-v4-final64/result.json)、[ASIC 64 样本](../../build/torus/soc-asic-area-v4-final64/result.json)、[ASIC 快照](../../build/torus/soc-asic-tapall-area-v4-snapshot/result.json)、[功能汇总](../../build/torus/area-v4-functional.json)。
- [32-word 对照面积](../../../eda-runs/20261029-torus-area-cache32-baseline/mynpu/chip_synth/area.rpt)、[独立 PE 面积](../../../eda-runs/20261029-torus-area-v4-pe/mynpu/torus_pe_synth/area.rpt)、[当前完整运行冻结清单](../../../eda-runs/20261029-torus-area-v4/inputs/source_manifest.json)。

[面积／功能／实际布局汇总](../../build/torus/area-v4-validation.json) 记录当前 98 个 RTL 输入与冻结快照完全一致、库文件哈希一致，以及所有最终功能回归无运行期间输入变化。

当前报告：[综合面积](../../../eda-runs/20261029-torus-area-v4/mynpu/chip_synth/area.rpt)、[QoR](../../../eda-runs/20261029-torus-area-v4/mynpu/chip_synth/qor.rpt)、[映射时序](../../../eda-runs/20261029-torus-area-v4/mynpu/chip_synth/timing.rpt)、[最终结构检查](../../../eda-runs/20261029-torus-area-v4/mynpu/chip_synth/check_design.rpt)、[floorplan 容量](../../../eda-runs/20261029-torus-area-v4/mynpu/pnr/reports/floorplan_check.rpt)、[实际放置失败日志](../../../eda-runs/20261029-torus-area-v4/mynpu/pnr/03_launcher.log)。

```bash
python3 tools/collect_torus_area.py --run ../eda-runs/20261029-torus-area-v4 --baseline ../eda-runs/20261029-torus-v3-target20k --functional build/torus/area-v4-functional.json --out build/torus/area-v4-validation.json
```

运行结果记录源码／资产 SHA256 与运行期间变化列表。构建产物由 Git 忽略；后端目录保留日志、报告和数据库。EDA／GUI 操作见 [后端教程](../../eda/tsmc180/README.md)。改动未提交或推送。
