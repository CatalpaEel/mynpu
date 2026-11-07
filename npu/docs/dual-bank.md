# 双 bank NMC 与队列化 NPU 设计

> 下文是加入 JTAG 前的双 bank 验证快照。后续新增的 DM/SBA、bootstrap 与复位语义及当前测试，见 [JTAG 说明](jtag.md)。

基于 `CatalpaEel/mynpu` main `c101c29`，本地分支 `experiment/dual-bank-queued`。本次目标是两个 SRAM 的独立带宽、NMC 寄存器缓存、任务队列、时序优化和 MNIST 小于 20k 周期。不是恢复旧 4×4 torus，而是在当前 main 的 CPU＋CNN／矩阵／向量架构上改进。

## 双 bank 与缓存

`npu_core` 对外暴露：`sram_req_o[1:0]`、`sram_wen_o[1:0][3:0]`、`sram_addr_o[1:0][10:0]`、`sram_wdata_o[1:0][31:0]`、`sram_rdata_i[1:0][31:0]`。两块宏均为同步、单端口、2048×32、字节写使能，获准后一周期读响应。

| 地址 | 物理 SRAM |
|---|---|
| `0x80000000..0x80001fff` | bank0，8KB |
| `0x80002000..0x80003fff` | bank1，8KB |

地址 bit13 选 bank，bits12:2 为宏内字地址。每 bank 独立轮询八个 master：CPU 数据、矩阵／CNN 共用口、向量、host、CPU 取指、RX、TX、COPY/FILL DMA。不同 bank 每周期最多各接受一个事务，共两次；同 bank 排队，不丢请求。MMIO 仍捕获一次请求，经过寄存器级后返回，发射该级时保留一个仲裁气泡以保护响应归属。

CNN 自身仍只有一个 NMC 请求 master，不能在同周期从两个 bank 发出两个 CNN 请求。双端口峰值由不同 master 并发使用，例如 CNN 参数预取和 CPU／DMA 访问激活；因此不能把新接口直接等同于 CNN 带宽翻倍。

每 bank 有默认 16 个 32bit 数据 word，合计 **128B NMC 寄存器缓存**，另有 valid、tag。`NMC_CACHE_WORDS` 支持 4～64 的 2 次幂，默认 16；缓存按地址直接映射，同 bank 的所有 master 共享缓存，不复制整份权重。

- 读命中：返回 cache word，仍遵循一周期响应。
- 未命中：读该 bank 的 SRAM，返回时填入 cache。
- 写：直接写 SRAM，不在 cache 中保存脏数据；只失效同地址 word。部分字节写也精确失效。
- 新写与旧读 fill 同拍冲突时，失效优先，避免旧数据重新变成有效项。
- 两个 cache 每周期各提供一个 32bit word；同 bank 不支持多个 master 同周期命中并行服务。
- reset 清 valid；没有软件可寻址 cache 数据窗口，也没有额外 SRAM。

配置／统计寄存器相对 `0x40000000`：

| 偏移 | 含义 |
|---|---|
| `0x000` | 版本 ID `0x4e505532` |
| `0x020 / 024` | bank0／1 cache read hit 次数 |
| `0x028 / 02c` | bank0／1 cache read miss 次数 |
| `0x030 / 034` | bank0／1 接受的所有存储事务数，含 hit 和 write |
| `0x038` | `{banks=2,width=32,total_bytes=16384}` |
| `0x03c` | `{banks=2,words_per_bank=NMC_CACHE_WORDS}` |

统计复位清零、32bit 自然回绕。CPU、DMA、host 对 SRAM 的写都经过 NMC，因此统一失效；软件仍须拥有活动张量和代码，不能在 CNN 已预取后修改相应数据，或在 CPU 正执行时覆盖代码。

## 矩阵与向量任务队列

每单元两项待执行 FIFO，加一项 active。CPU 写 shadow CSR，CONTROL.start 保存地址、维度／长度及运算选择的快照；后续配置不会改变 queued／active。任务完成后自动启动下一项，无需 CPU 逐项轮询发 start。地址只在完整 32bit 校验成功后压缩成队列中的 14bit 偏移，避免截断非法地址。

| 单元 | 原接口 | 新接口 |
|---|---|---|
| 矩阵 | `0x100..0x120`，INT8 单字元素，INT32 结果，M/N/K=1..16 | `0x124` 队列容量／占用，`0x128` 完成数，`0x12c` 提交数 |
| 向量 | `0x200..0x220`，INT32 ReLU／补码回绕 Add，长度1..1024 | `0x224` 队列容量／占用，`0x228` 完成数，`0x22c` 提交数 |

队列寄存器高16bit为容量2，低16bit为 pending 数，active 不计入。STATUS.busy 覆盖 active、start 和 pending。done 是粘滞的单任务完成事件；要等待特定批次应使用完成计数，或等待整个队列 drain。CONTROL.clear 在忙时不清队列而置错。

满队列提交不覆盖旧项，host 得到 error，sticky error 置位，原工作继续。非法描述符不入队。空闲时接受下一项合法任务会按旧 start 语义清错误；批量软件也可在 drain 后显式 clear。两个 CSR producer 必须由软件串行化；硬件不提供描述符多写者事务。

矩阵与 CNN 共用 master1：矩阵排队可等待 CNN，pending／start／active 互锁阻止新的 CNN 越过已排队矩阵。向量可独立执行；跨单元依赖和地址冲突仍由软件管理，同单元队列按 FIFO 顺序完成。软件 API 在 `sw/npu.h`，start helper 现在按队列空间提交，提交计数确认是否接受。

## DMA 校验与时序

原最差路径是 DMA 的 rows／stride 乘法、范围终点加法和复制区间重叠比较连在一拍。现在 START 冻结配置，依次执行：

1. 计算 `(rows-1)*stride`，保存乘积。
2. 计算包含基址和 row_bytes 的范围终点。
3. 检查完整字段、16KB 边界、对齐与源／目的包络重叠，合法才发出 DMA start。

中间结果保留足够位宽，先检查完整字段再使用低位；不能通过大值截断或加法溢出访问低 SRAM。校验期间 STATUS.busy=1，描述符禁止改写，支持 abort。未启动的任务 BYTES_DONE／CYCLES 为0；取消校验不会暴露上一任务计数。实际 DMA 工作时仍保留 committed-byte、timeout、stream abort 和部分完成语义。

RX/TX/MEM 仍为三个单 word 暂存通道，支持 1D／2D、独立 stride、copy／fill、尾部 byte enable。有效 SRAM 范围扩大到16KB，行长1..16384、行数1..2048，起点／行步长仍须4字节对齐。源 stride=0 可重复行，目的多行不允许0；部分行重叠及 copy 包络重叠仍受保护。

## CNN 与软件协同

单 MAC 的 40770 次乘加无法在20k内完成。因此把每个水平卷积行的三个 tap／FC 的三个元素并行乘加，仍更新一个输出的24bit部分和；不新增整层缓存或权重副本。零点、padding、Q24 ties-even、bias、ReLU 与饱和的整数结果保持不变。FC 任意尾部使用 product mask，三通道输出的尾字节也正确打包。

继续复用 CNN 的128B当前／下一块工作集；相同权重 tag 可保留或从另一缓冲复制。加载器直接准备下一有效输入行，跳过每行 PREP 气泡；最后响应前递到 ready 判定，同沿的下一次 launch 优先于上一组完成清除。该优先级防止新的预取被误清，从而减少等待。

程序和激活在 bank0；唯一3932B参数像迁至 bank1 `0x80002000`。CPU 仍逐层发任务，CNN 内部执行层内循环，区别于旧 torus 的逐条 PE 发令。

| 单图布局 | 地址 |
|---|---|
| 程序加载像4KB，含填充 | `0x80000000..0x80000fff` |
| CPU入口／描述符 | `0x80000080`／`0x80000800` |
| 激活 A／B，各784B | `0x80001400`／`0x80001800` |
| mailbox | `0x80001f00` |
| 参数3932B，仅一份 | `0x80002000..0x80002f5b` |

连续流 A／B／C 为 `0x1360/0x1670/0x1980`（均加 SRAM 基址），结果包在 `0x1c90/0x1ca0`，所有权 mailbox 在 `0x1fa0`。程序／描述符与单图一样使用 bank0 前4KB。各帧完整初始化第一层，后续只写变化字段，84次字段写降至62；连续流不再对每个字段循环比较地址，argmax 按packed word复用读取。

## 实测与限制

| 指标 | c101c29 原始 main | 本次 |
|---|---:|---:|
| 单图含 CPU 配置／argmax | 41830 | **18713** |
| 六层 kernel busy | 41095 | **18178** |
| 输入 RX DMA 配置与搬运 | 617 | 620 |
| 含输入到分类完成 | 42447 | **19333** |
| 20张连续流平均周期／张 | 42974.55 | **19112.45** |

单图严格小于20k，测试台独立计钟；模型、程序首次装载不计入。单图10个样本，逐层和边界18053项精确检查，20张连续流的logits与类别均通过。两块实际宏的功能模型结果／周期一致，宏内部 timing check 关闭。本轮未重新运行 PyTorch／全10000张准确率，未进行实板测试。

功能回归还包括：完整CPU SoC1241项、NMC双bank轮询／cache／fill-write竞态、队列55项、DMA取消／超时与写确认、2×2 NoC481项和远端启动MNIST。旧的单MAC利用率分母已改为每周期三个乘积。

综合采用TSMC180 TT。为争取50MHz裕量，以16ns为综合优化目标，再对同一网表按20ns输出报告，两套报告均保留；没有运行布局布线，不能据此宣布物理频率或2mm×2mm放置通过。最终面积／时序及哈希见 [验证汇总](../reports/dual_bank_validation.json) 和 [EDA说明](../eda/tsmc180/README.md)。

## 本轮综合最终结果

完整运行 `eda-runs/20261101-dual-bank-v8-full` 已正常结束；当前RTL／库哈希与冻结快照一致。Genus19.17、TSMC180 TT、medium generic/map/opt：

| 项目 | 原 main 单 bank | 当前双 bank |
|---|---:|---:|
| Cell Area，含实际 SRAM | 1.364122mm² | **1.986412mm²** |
| SRAM 宏 | 1片，0.401444mm² | 2片，**0.802887mm²** |
| 标准单元 | 0.962679mm² | **1.183525mm²** |
| 20ns setup slack | +0.0001ns | **+4.0007ns** |
| 20ns TNS／违例路径 | 0／0 | 0／0 |
| 综合优化目标 | 20ns | 16ns，再按20ns评估 |

总单元面积增加约45.6%，其中一片额外SRAM贡献约0.4014mm²；逻辑面积约增加22.9%，包含三路乘积、缓存、队列、校验流水和更紧目标的综合策略，不能全部归因于某一个结构。单图周期下降 **55.26%**。

同一最终网表在16ns下setup slack +0.0007ns、TNS=0；按20ns重新分析为+4.0007ns。最差路径从CPU取指指令寄存器经过译码／请求／缓存判断到NMC的cache_hits统计寄存器，数据路径约15.087ns；原DMA范围／重叠检查已不在最差路径。

确认有两片真实SRAM宏，无unresolved／empty module，无未驱动／多驱动leaf pin或顶层port；优化后仍有1840个undriven hierarchical pin报告，不能表述为所有层级检查全零。没有运行CTS、布线后hold／setup或物理签核，也未证明2mm×2mm已放置成功。

原始报告位于工作区父目录的上述运行目录：`reports/area.rpt`、`qor.rpt`、`timing.rpt`、`optimized_synth_clock_qor.rpt` 和 `check_design.rpt`。可移植摘要和所有最终功能结果的SHA256见 `npu/reports/dual_bank_validation.json`。生成脚本为 `npu/scripts/collect_dual.py`。

最终映射网表另通过1个样本的真实CPU端到端功能仿真，十个logits、分类、六层完成标志均正确，含输入仍19333周期。该测试使用实际标准单元／SRAM功能模型，无SDF、零延迟、timing check关闭，不是布线后仿真。日志在 `npu/build/gate-dual-final/`，重现命令：

```bash
/usr/bin/python3.12 npu/scripts/run_gate.py   --run ../eda-runs/20261101-dual-bank-v8-full --tag local --samples 1
```
