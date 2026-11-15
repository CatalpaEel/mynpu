> 后续：2026-11-15已完成布局布线和bitstream生成，见[实现结果](BITSTREAM-20261115.md)。下文保留综合优化阶段记录。

# EGo1 LUT优化实测（2026-11-14）

基于 `ba23677` 的本地RTL修改，无GPIO、无外部Host。Vivado 2025.2，XC7A35T-CSG324-1，10MHz，`--area-medium --cpu-rf-lutram --cnn-dsp --threads 4`。保持MAC数量、精度、RF容量、任务队列和流FIFO深度；不增加数据锁存器。

## 哪些部分占用最多

以下均为opt_design后的层次LUT，不将父模块与子模块重复相加。

| 模块 | 原版LUT | 优化后LUT |
| --- | ---: | ---: |
| XBAR，含RF与流FIFO | 6773 | 6296 |
| CNN Stream | 2431 | 2427 |
| Matrix Stream | 1853 | 1916 |
| Vector Stream | 1950 | 1975 |
| CPU | 2887 | 2924 |
| MMIO | 1696 | 1696 |
| 共享量化 | 1028 | 1025 |
| Debug | 1015 | 992 |

原版XBAR约32%，三个Stream约30%；纯CNN/Matrix/Vector计算逻辑合计约6%，乘法部分另使用DSP。优先优化互联和存储推断。综合会跨层次调整逻辑归属，模块局部变化不能直接当作独立优化收益。

## 实施的修改

1. **XBAR利用已有one-hot仲裁结果选择宽请求数据。** SRAM/辅助接口地址、写数据、字节使能采用one-hot掩码选择；返回数据按固定master路由，避免宽动态索引。保持原仲裁和响应优先级。无有效事务时的无效载荷可能变为0，接受事务的行为不变。
2. **多操作数读回固定lane写入。** 用固定lane比较代替动态打包数组写入，保留返回顺序、故障处理和背压。
3. **流FIFO数据写入与复位控制分开。** 4×8×32位payload采用无复位、单写口、异步读模板，FPGA标注distributed RAM。控制状态仍复位；保持空队列旁路、满队列同拍读写、字节掩码和深度。Vivado实际推断出四组RAM32M，每组6个。ASIC没有该属性，仍使用触发器。

## 实测结果

| opt_design结果 | 原版 | 第一轮互联改写 | 加FIFO存储推断 |
| --- | ---: | ---: | ---: |
| 总LUT | 20956 | 20890 | **20573** |
| Logic LUT | 20820 | 20754 | 20341 |
| LUTRAM | 136 | 136 | 232 |
| FF | 14196 | 14193 | **13169** |
| RAMB36 | 4 | 4 | 4 |
| DSP | 58 | 58 | 58 |

总计减少383 LUT（1.83%）、1027 FF。总LUT占98.91%，剩227个；默认资源检查开启，最终opt DRC没有Error，仍有DSP流水与BRAM异步控制等Warning。完整综合阶段仍为20919 LUT，经标准opt_design降到20573；没有关闭容量检查。

**尚未执行当前优化版布局布线，不能据此宣称实现通过、时序收敛或可生成bitstream。** 综合容量余量仍小。

## 验证与ASIC影响

最终源码VCS通过：xbarstream、xbarconcurrent、jtagrunning、latency、sharedoperands、unitroutes。结果中的源码SHA256逐项与当前文件核对，无运行期间变更。CPU运行期间真实JTAG/SBA测试1161项，2278次grant对应2278次reply；不使用Host或halt绕行。

MNIST 10个样本全部通过，测得每帧elapsed 21728周期（含723周期命令阶段），扣除该阶段21005周期，与第一轮相同；本次是资源优化，没有声称达到20k。

TSMC180/20ns/high effort的独立模块Genus探针：XBAR cell面积318251.315→318444.493µm²（+0.061%）；FIFO 87783.853→87731.168µm²。前者固定旧FIFO，后者独立比较FIFO模板；不能将其当作最终全芯片面积、时序或签核结果。

## 证据位置

运行根目录为项目上一级的 `eda-runs/`：

- 基线：`20261114-ego1-main-ba23677-vivado2025-synth10/`
- 第一轮：`20261114-ego1-main-ba23677-onehot-v1/`
- 最终：`20261114-ego1-main-ba23677-onehot-fifo-v2/`
- ASIC独立探针：`20261114-lutopt-asic-xbar/`、`20261114-lutopt-asic-fifo/`

各FPGA目录包含输入快照、source_manifest、Tcl、日志、DCP与资源/DRC报告。项目内汇总为 `npu/reports/ego1_lut_optimization_20261114.json`，原始资源与DRC副本在同名目录。仿真证据在 `npu/build/vcs-lutopt-fifo*/result.json`。

后续进一步压LUT的重点仍是RF读端选择网络和Stream地址/供数逻辑；本轮未减少访存接口、RF容量或计算能力。
