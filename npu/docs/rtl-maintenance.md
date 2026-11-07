> 本页中的CRW1、CNN FC模式及性能/面积结果属于历史版本。当前CNN已移除FC，见[CRW2卷积专用化与Matrix FC](cnn-conv-only.md)。通用Vector指令设计仍沿用。

> 历史阶段记录：当前 CNN 原始结果、vector 后处理及双 bank regfile 见 [当前架构](regfile-vector.md)。本文数值与旧 ABI 仅对应当时快照。

# RTL 整理与维护约定

本轮合并重复控制与运算表达式，补齐模块内的时序和边界条件说明。CNN、matrix、vector 仍为独立单元；未改变 CRO2、matrix/vector 寄存器接口、FIFO 深度、算子或整数输出。

## 本次整理

| 模块 | 精简/整理 | 关键注释 |
|---|---|---|
| [CNN 包](../rtl/npu_cnn_pkg.sv) | 固定实现上限集中命名；配置合法性分为公共、Conv/FC 形状、范围、输出重叠条件；打包使用命名字段 | 104bit 快照、14 个 shadow 字段、先校验完整 32bit 值再截位；FC 的 stride 继续忽略 |
| [CNN 执行核](../rtl/npu_cnn_engine.sv) | 两处预取调用合为一个入口；复用握手、排空和操作数判定；统一 U8 零点减法；复用 FC 最后一个 beat 条件 | SRAM 一周期响应、bank 元数据稳定期、同拍完成/预取优先级、尾 word 字节使能 |
| [CNN 算术流水线](../rtl/cnn/npu_cnn_mac.sv) | 使用集中定义的 tap/上下文数量 | 24bit 部分和、final 消费并清空上下文、Q24 乘加位置、负数 ties-to-even、零点/ReLU/饱和顺序 |
| [CNN 控制](../rtl/npu_cnn_control.sv) | 能力查询使用统一常量 | shadow/FIFO/active 区别、pending 所有权、统计重置、错误最高优先级 |
| [matrix](../rtl/matrix/npu_matmul.sv)、[vector](../rtl/vector/npu_vector.sv) | 原先分散在 4/3 个 WAIT 状态的错误分支，各收敛为一个出口 | 仅等待响应时消费 error、fault/done 单周期脉冲、故障不回滚已接受写入 |
| [NMC](../rtl/nmc.sv) | 删除重复的 2bit `read_q`：`miss_q` 已表示接受的读 miss | bank 地址拆分、三路仲裁、MMIO 延迟、owner 排除和 fill/invalidate 优先级 |
| [MMIO](../rtl/control/npu_mmio.sv)、[顶层](../rtl/top/npu_core.sv)、[DMA](../rtl/npu_dma_channel.sv) | 保持控制逻辑 | 注册 start 与 busy 间隔、FIFO 同拍 push/pop、主端口分工、stride 从行起点计算 |

CNN 常量是固定实现约束，不是新增的独立可配置参数。实际硬件没有增加 PE、缓存或队列；也没有删掉边界检查、统计接口或调试功能。删除冗余 RTL 标志不等于已测得相应硅面积减少，综合器原本也可能消除该冗余。

## 修改时必须保留的契约

1. **请求接受与响应不是同一事件。** matrix/vector/DMA 等待 `rvalid`，包括写应答。CNN 私有 SRAM 端口依赖当前 NMC 的一周期响应；如接可变延迟总线，必须同步修改 pending 跟踪。不要直接复用到任意延迟总线。
2. **错误只在拥有响应时生效。** `error` 没有 `rvalid`，或出现在 IDLE/请求尚未接受时，不应让 matrix/vector 报 fault。故障后必须停止当前任务，不能在最后写应答错误时同时置 done。
3. **缓冲只能在完成后复用。** CNN 一行任务结束时需要排空操作数、整数后处理、部分字、输出 FIFO 和在途写应答。MAC 的 `zero_i/relu_i` 没有独立流水寄存，调用方必须保持到 `pending_o` 清零；当前执行核通过保持 active command 到 DRAIN 结束满足这一约束。
4. **保持赋值优先级。** 同拍 load complete 和新预取时，新 bank 预留最后生效；NMC 同拍旧 fill 和新写时，相关 invalidate 最后生效；CNN engine fault 覆盖同拍 enqueue/CSR clear。不要仅为“合并 always 块”打乱顺序。
5. **保持整数与打包语义。** U8 减输入零点需要 signed 9bit；INT8 权重为 signed 8bit；Conv padding 不访问无效列，16..27 列索引必须无符号。量化 bias 在 `dot * multiplier` 之后、Q24 右移之前相加，不能移进原始累加。输出首尾 word 使用 byte enable，不能覆盖相邻字节。
6. **保留软件调度边界。** 一次 CNN 命令仍是单通道单行/单 FC 点积；CPU 调度行、输出通道和层。MMIO 在 enqueue 时校验完整 CSR 值并快照，后续 shadow 写入不影响已经排队的工作。

## 验证

[rtl_tidy_validation.json](../reports/rtl_tidy_validation.json) 保存本轮源码哈希、基线快照、回归日志和结果：

- 13 项 RTL 回归全部通过：原有 12 项加上 `enginefaults`。
- [tb_engine_faults.sv](../tb/tb_engine_faults.sv) 对每个响应位置注入错误，覆盖 matrix 的 A/B/旧 D 读取/结果写入、vector 的 A/B/写入，以及 stray response、缺少 rvalid、重试和复位。12 次故障及 12 次不复位重试，共 558 项检查；相同测试在整理前冻结 RTL 上也通过。
- CNN 校验和 104bit 打包与整理前版本对照 20,000 组：8,549 组合法、11,451 组非法；判断和打包结果一致。
- 逐层推理 19,033 项逐值检查通过；单图仍为 **19,825 周期**，含输入 **20,445 周期**；20 帧 **406,016 周期**，平均 **20,300.8 周期/帧**。固件、参数、输入和 golden 未改。
- `make format-check`、Python 语法和 C 头文件语法检查通过。

完整运行和整理前快照在 `../eda-runs/20261103-code-tidy/`。本轮没有重新综合、网表仿真或布局布线，不用旧 PPA 报告声称本版面积/时序已重新测量。

从仓库根目录复现关键测试（使用新 tag）：

```sh
make format-check
/usr/bin/python3.12 npu/scripts/run_vcs.py --suite enginefaults --tag NEW_TAG
/usr/bin/python3.12 npu/scripts/run_vcs.py --suite latency --macro --max-cycles 20000 --tag NEW_TAG
/usr/bin/python3.12 npu/scripts/run_vcs.py --suite layers --macro --tag NEW_TAG
/usr/bin/python3.12 npu/scripts/run_vcs.py --suite nmcconcurrent --tag NEW_TAG
```

固定基线对照的 fixture 和编译命令保存在运行目录的 `contract/` 与 `baseline-faults/`；使用当前已有报告时应核对记录的源码哈希，而不是覆盖历史测量。
