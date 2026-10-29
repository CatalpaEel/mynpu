# 优化后验证记录

2026-10-29，软件控制 torus，ABI 2，VCS Q-2020.03-SP2-7。旧版串行结果保留在 [validation-v1.md](validation-v1.md)。

## 性能

| 版本 | 六层计算到 SRAM 写回 | 含最后 CPU argmax |
|---|---:|---:|
| 旧版，完整重复配置、串行搬运 | 167828 | 旧口径未计入 |
| 新版配置复用、边界／发令优化，关闭预取流水 | 70542 | 70681 |
| 同一新版软件，开启预取流水 | **68686** | **68825**（首个样本） |

两个存储后端的 8 个样本均为 68686 个六层周期；含 argmax 的周期为 68825～68828，随分类比较分支略有差异。相对旧版，六层周期减少 **59.1%**。同版本 A/B 对照中，预取流水单独节省 **1856 周期，2.63%**；其余改善来自配置复用、倍率复用、边界 mask 计算与 CPU 汇编寄存器分配优化，不能全部归因于搬运重叠。

描述符写从旧代码静态计数的 **8372 次（161×4×13）降到实际计数的 976 次**，减少 88.3%。软件主循环保持每层写回 SRAM；开启全部逐层快照时，ASIC 单样本的六层计时为 83147，含 argmax 为 83286。

**仍未达到小于 20000 周期的目标。** 当前 CPU 逐项发令、取指／元数据读取和同一数据 bank 的带宽仍有开销，且没有层融合或 torus 数据复用。接口的连续 64 周期吞吐测试不能代替推理性能。

## 重叠证据和功能检查

- 每次推理有 **2978 条非零行 mask PE 运算在活动输入预取期间被接受**。
- 测试台观察到 **1161 个被接受的 SRAM 读请求与 PE 运算在同周期发生**。
- 相同软件关闭预取流水时，上述两项均为 0；流水版 MAC 的直接命令等待计数为 0，等待转移到 EXCHANGE/COMMIT 边界。
- 每个样本实际 SRAM 读请求数为 6941，串行／流水一致。计数指标可重叠，不能简单相加作为完整的周期分解。

| 功能回归 | FPGA BRAM 模型 | ASIC SRAM 功能模型 |
|---|---|---|
| 定向检查 | 1778 项通过 | 1778 项通过 |
| 8 个 MNIST 样本 | 六层 14352 字节全部符合整数 golden | 同左 |
| 原生 CPU 连续命令 | 连续 64 周期各接收一条，结果正确 | 同左 |
| JTAG | SRAM 装载、别名、并发无关地址访问、halt/resume | 同左 |
| 逐层快照 | 此优化版本未重跑独立快照用例 | 首个样本六层快照经 SBA 全部读回校验 |

新增检查覆盖：预取不提前覆盖 PE；提交的目标寄存器不被提前推进的游标改变；变化的行 mask；同周期发布并预取下一项；末项排空不越界；被阻塞的配置写与直接 COMMIT 并存；FULL store 的源寄存器保护；FULL load 的 RAW/WAW 和邻居读取保护；独立寄存器计算与普通 load/store 重叠。

全部数值运算仍在 PE 内。输入预取复用原有两口各四个 gather 数据寄存器，没有增加 PE 架构寄存器、指令 RAM、第三块 SRAM或层执行状态机。CPU 程序为 3008B，唯一参数像仍为 4288B。整数 golden 用原始 M/2^31；硬件像用 2M 和 PE MULHR，与已记录的 PyTorch 最终输出最大差 1 code。本次未重新执行 PyTorch，也未验证完整数据集准确率。

计时从 CPU 接收启动请求后开始，不包括 JTAG 上传输入、启动命令吞吐自测和完成报告的 MMIO 写；`layer_cycles` 在 argmax 前读取，`cycles` 在 argmax 后读取。普通回归关闭逐层快照，期间有并发无关 SBA 访问及状态轮询。

本次没有综合或布局布线。ASIC 仿真关闭宏 timing checks，仅证明功能；尚无新版本的 50MHz、2mm×2mm 面积或功耗结论。

## 复现及证据

```bash
python3 tools/build_torus.py --out build/torus/overlap --vectors 8
python3 tools/run_torus.py --memory fpga --suite unit --tag overlap
python3 tools/run_torus.py --memory asic --suite unit --tag overlap
python3 tools/run_torus.py --memory fpga --suite soc --assets build/torus/overlap --tag overlap8
python3 tools/run_torus.py --memory asic --suite soc --assets build/torus/overlap --tag overlap8
python3 tools/build_torus.py --out build/torus/serial-one --vectors 1 --serial
python3 tools/run_torus.py --memory fpga --suite soc --assets build/torus/serial-one --tag serial-one
python3 tools/build_torus.py --out build/torus/overlap-one --vectors 1
python3 tools/run_torus.py --memory fpga --suite soc --assets build/torus/overlap-one --tag overlap-one
python3 tools/run_torus.py --memory asic --suite soc --assets build/torus/overlap-one --tap-all --tag overlap-one
```

每项 result.json 包含通过状态、实际输出、公共源文件及运行资产 SHA256，以及运行期间源文件是否变化。所有最终运行均无输入变化：

- [unit-fpga-overlap result](../../build/torus/unit-fpga-overlap/result.json) · [run.log](../../build/torus/unit-fpga-overlap/run.log)
- [unit-asic-overlap result](../../build/torus/unit-asic-overlap/result.json) · [run.log](../../build/torus/unit-asic-overlap/run.log)
- [soc-fpga-serial-one result](../../build/torus/soc-fpga-serial-one/result.json) · [run.log](../../build/torus/soc-fpga-serial-one/run.log)
- [soc-fpga-overlap-one result](../../build/torus/soc-fpga-overlap-one/result.json) · [run.log](../../build/torus/soc-fpga-overlap-one/run.log)
- [soc-fpga-overlap8 result](../../build/torus/soc-fpga-overlap8/result.json) · [run.log](../../build/torus/soc-fpga-overlap8/run.log)
- [soc-asic-overlap8 result](../../build/torus/soc-asic-overlap8/result.json) · [run.log](../../build/torus/soc-asic-overlap8/run.log)
- [soc-asic-tapall-overlap-one result](../../build/torus/soc-asic-tapall-overlap-one/result.json) · [run.log](../../build/torus/soc-asic-tapall-overlap-one/run.log)

构建资产：[manifest](../../build/torus/overlap/manifest.json)、[CPU ELF](../../build/torus/overlap/cpu.elf)、[CPU hex](../../build/torus/overlap/cpu.hex)、[模型参数像](../../build/torus/overlap/model.hex)、[逐层 golden](../../build/torus/overlap/golden.hex)。`build/` 由 Git 忽略，可按上述命令重建。

实现与流水时序说明见 [README.md](README.md)、[overlap.md](overlap.md)。改动在独立 `mynpu-torus` 工作区，未提交或推送。
