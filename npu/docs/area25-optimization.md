# 向2.5mm²压缩：逻辑精简与ASIC综合

本轮以Stream精简版 `dea650e` 的2.846849mm²为基线。面积包含两块8KB SRAM宏，不含PAD、CTS、布线、filler和放置留白；目标不是2.5mm² die尺寸。未重跑PNR。

## RTL改动

- Matrix：每个累加器先选乘积或seed，再走一个INT32加法器，去除动态索引seed读回树。16路INT16乘法、16个INT32累加器、掩码、flush和输出握手保留。
- MMIO：Matrix/Vector FIFO只复位head/tail/count，内容通过占用数失效，移除不可见payload复位；深度仍为8/8/8。所有可读配置寄存器的复位值保留。
- 地址范围检查：先限制32位长度，再用16位带进位的孔径内终点计算；保留SRAM/RF边界、零长度、非法高位和溢出检查。FIFO的环绕地址语义保留。MMIO重叠检查只在完整范围检查也通过时使用，合法长度至多4096 words。
- QT01：CSR仍允许shift=0..32。INT64乘积和加偏置保留，只缩窄舍入后的结果与被丢弃位掩码；低32位回绕、零点、ties-to-even与裁剪不变。

本轮没有修改软件、权重或golden；未缩减256B共享RF、4条16words流FIFO、CNN预取窗口、INT16/INT32能力或JTAG功能。

## 综合策略

增加 `prepare_run.py --clock-gating`，让Genus提取标准单元库ICG，替代大量寄存器的逐bit反馈选择。RTL与FPGA保持原时钟及使能语义。ASIC门控后的网表单独做零延迟功能测试。

对照包括原RTL的low/high门控综合，以及精简RTL的low/high门控综合。原设置为16ns优化、20ns报告；另从精确映射DB调整优化周期，比较利用时序余量能减少多少面积。不能把余量接近零的20ns结果当作物理时序收敛。

最终选用18ns优化、20ns报告、寄存器感知增量门控的映射网表：**2.515488mm²**，其中标准单元1.712601mm²、两块SRAM0.802887mm²。相对基线减少 **11.64%**；严格2.5mm²尚未达到，超出0.015488mm²（0.62%）。50MHz sys_clk setup slack **+2.0040ns**，所有clock/门控使能cost group的TNS均为0、违反路径均为0。

| 测量版本 | 优化周期 | 总Cell Area mm² | 50MHz setup slack ns |
|---|---:|---:|---:|
| 原Stream精简版，low，无自动门控 | 16ns | 2.846849 | +4.0020 |
| 原RTL，low，自动门控 | 16ns | 2.680148 | +4.0005 |
| 原RTL，high，自动门控 | 16ns | 2.533809 | +4.0001 |
| 本轮RTL，low，自动门控 | 16ns | 2.649413 | +4.0051 |
| 从本轮low DB按20ns做high增量优化 | 20ns | 2.593327 | +0.0004 |
| 本轮RTL，全量high，自动门控 | 16ns | 2.518886 | +4.0031 |
| 从全量high DB再优化 | 18ns | 2.516063 | +2.0017 |
| 从全量high DB再优化 | 19ns | 2.515808 | +1.0071 |
| 从全量high DB再优化 | 20ns | 2.515742 | +0.0920 |
| 18ns DB再做寄存器感知增量门控（选用） | 18ns | **2.515488** | **+2.0040** |

RTL精简本身的同low配置收益为0.030735mm²；其余收益主要来自门控和更强的综合优化，不能全部归因于架构改动。20ns几乎不再节省面积，却明显消耗时序余量。因此选择18ns版本。

High effort会展开部分计算核层级，层级表中的“Top/core glue”含已展开的计算逻辑，不代表纯顶层胶合面积；本轮仅用全芯片总Cell Area作可靠比较，不把缺失层级当作计算核面积为零。

[机器面积报告](../reports/area25_area_validation.json)包含各次测量目录、原始报告位置、源码/网表哈希和门级测试记录。最终原始报告：[面积](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-area25-high-18ns-regaware/reports/area.rpt)、[时序](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-area25-high-18ns-regaware/reports/qor.rpt)。

## 功能验证

[回归报告](../reports/area25_validation.json)核对每项测试的当前源文件哈希，共25组重新运行的RTL验证。默认VPG2、共享QT01和旧固件分别为29,173、27,432、30,710周期/张，与本轮前一致；各测试10张MNIST。两条当前软件路径各60个中间层张量、17,940字节与golden逐字节匹配。

地址范围与原33位实现作对照，256B/2KB RF配置各986,816组；队列覆盖复位、溢出、快照和并发。其余测试覆盖完整GEMM/INT16回绕、CNN stride/padding、Vector程序、RF并发、流转发、错误恢复和JTAG。

最终门控映射网表另验证193个CNN任务、六种单元连接与三阶段链，以及CPU执行共享量化MNIST的一张图（分类与10个logits均核对）。该测试使用真实工艺标准单元与SRAM Verilog模型、禁用时序检查，不含SDF，不等同于物理时序签核。

## 复现

```bash
python3.12 npu/scripts/collect_area25_validation.py
python3.12 npu/eda/tsmc180/prepare_run.py --out /path/to/new-run --effort high --clock-gating
cd /path/to/new-run
genus -no_gui -batch -files synth.tcl > launcher.log 2>&1
```

从已完成且与当前RTL哈希一致的映射DB重做面积优化：

```bash
python3.12 npu/eda/tsmc180/prepare_reopt.py --seed /path/to/completed-run --out /path/to/new-reopt --period 18
cd /path/to/new-reopt
genus -no_gui -batch -files synth.tcl > launcher.log 2>&1
```

选用版本在上述18ns结果上再执行一次相同period的 `prepare_reopt.py --register-aware`。脚本保存种子DB的SHA256和全部冻结输入，必须逐级复现，不能只把一次low综合改成high增量优化就当作全量high结果。

在仓库目录采集面积、全部时序cost group并运行门级检查：

```bash
python3.12 npu/eda/tsmc180/collect_area25.py --run /path/to/completed-run
python3.12 npu/eda/tsmc180/run_gate_smoke.py --run /path/to/completed-run --suite unitroutes
python3.12 npu/eda/tsmc180/run_gate_smoke.py --run /path/to/completed-run --suite cnnstream
python3.12 npu/eda/tsmc180/run_gate_smoke.py --run /path/to/completed-run --suite latency --tag quant --artifacts-dir npu/build/outer-artifacts
```
