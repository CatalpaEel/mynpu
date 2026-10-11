# 完整 SoC 验证记录

日期：2026-10-08。模拟器：VCS Q-2020.03-SP2-7，Linux。PyTorch checkpoint 重新导出使用 2.2.2+cpu / FBGEMM，生成的 8KB 参数镜像与仓库镜像逐字节相同。

## 完整 SoC 参数配置

| CPU SRAM | NPU SRAM | LANES | 结果 | 单轮 NPU CYCLE |
|---|---|---:|---|---:|
| 8KB | 8KB | 1 | PASS | 54132 |
| 8KB | 8KB | 8 | PASS | 10704 |
| 8KB | 16KB | 16 | PASS | 9882 |

每项包含 JTAG IDCODE、DMI/SBA 读写 CPU/NPU SRAM、真实 CPU 启动、halt/x31 读写及恢复、五轮六层推理、第一轮轮询、后四轮中断处理和清中断。CPU 每轮重新写入 784-byte 输入，testbench 在每轮的每一层都检查输出，合计 30 个 layer checkpoint、8970 个 output byte；每个 byte 对独立整数参考严格相等，并检查与 PyTorch code 的绝对差 ≤1。测试要求 IRQ 恰好产生四次、CPU handler 恰好处理四次，最终 mailbox 为 `0xc0dec0de`。`sim/tb_mynpu_soc.sv` 的 `INFERENCE_RUNS` 参数默认是 5，必须与固件的重复次数保持一致。

周期计数不含 CPU 加载参数/输入、JTAG 操作或读回结果的开销。它来自当前多访问功能数组后端，换成同步 SRAM 后必须重测。提高 LANES 到 16 收益有限，因为前四层输出通道数均 ≤8，尾层通道余数也影响利用率。

## PyTorch 与固定点参考

采用 exporter 中的确定性输入：784 个 FP32 值在 -0.4241..2.8200 均匀排列，reshape 为 1×1×28×28 后由 checkpoint QuantStub 产生输入 code。这是用于功能验证的固定向量，不是 MNIST 测试集评估。

| 层 | 输出 byte 数 | 与 PyTorch 不同的 byte 数 | 最大绝对差 |
|---|---:|---:|---:|
| Conv1 | 392 | 0 | 0 |
| Conv2 | 784 | 1 | 1 |
| Conv3 | 392 | 1 | 1 |
| Conv4 裁剪后 | 72 | 1 | 1 |
| Conv5 | 144 | 4 | 1 |
| FC | 10 | 1 | 1 |

```text
PyTorch / FBGEMM: 68 49 82 68 55 80 75 63 76 59
Integer / RTL:   68 50 82 68 55 80 75 63 76 59
Argmax: 2
```

整数参考由 `tools/build_firmware.py` 中独立的 Python Conv/FC 循环计算，处理 zero-point、padding、INT32 bias/累加回绕、Q31 requant、ReLU 和 clamp。PyTorch reference 由 exporter 实际执行 checkpoint 的 quantized ConvReLU/Linear 取得，包含 Conv4 的裁剪。两种参考分别保存为 `integer_layers.hex` 与 `pytorch_layers.hex`，testbench 同时检查。

checkpoint 的元数据记录 FP32 accuracy=99.07%、INT8 accuracy=99.01%、下降约 0.06 个百分点。这些是模型作者记录的数据，本次未重新运行完整测试集；尤其不能把它作为当前 Q31 RTL 的全测试集精度。

## 已知边界

VCS 启动时出现原 CPU `unique case` 在 time 0 未匹配的 warning，复位后自测通过。测试编译定义 `SYNTHESIS`，用于避开原项目中非必要的仿真辅助逻辑；新增 testbench 的断言、逐层比较和 CPU 自测仍实际执行。Vivado 2023.2 XSim elaboration 失败于原 AXI 的 `default disable iff`，未将其列为通过的后端。

`sim/tb_cnn_npu_sp.sv` 另外用 FPGA BRAM 后端连续运行 5 次，重新装载输入并检查 10 个 FC 输出，报告 480655 次状态轮询和 288390 个 NPU cycle。`sim/tb_mynpu_soc_fpga.sv` 在 VCS 中用 CPU BRAM + NPU 单端口 BRAM 跑同一份五轮固件；已通过，NPU cycle 为 288390。最新 RTL 在乘法、右移和 clamp 之间插入了三个时序阶段，以适应 FPGA/ASIC 中的乘法和组合路径。ASIC wrapper 已用课程提供的 RA1SHD Verilog model 完成 VCS 编译检查；该模型包含大量 timing checks，完整仿真需要在 PDK/宏仿真环境中按实际时钟约束运行，公开仓库不携带该 proprietary 文件。

EGo1 `xc7a35tcsg324-1` 工程已用 Vivado 完成综合、实现和 bitstream 生成，50 MHz MMCM 时钟的实现后 WNS 为 `+2.261 ns`，TNS 和 failing endpoints 均为 0，Vivado DRC error 为 0。实现日志仍有 RAM 异步控制信号的 `REQP-1839` warning；上板时需要观察复位期间 BRAM 内容和启动行为。尚未连接真实 EGo1、FT232H 探针并完成 bitstream 下载与 OpenOCD/GDB 联调。

尚未覆盖大量随机输入、全 MNIST 测试集、异常 descriptor、AXI 随机压力、多 hart、真实探针下载、OpenOCD/GDB 联调或物理 SRAM 宏的 STA。FBGEMM bit-exact、面积/功耗/最高频率也尚未完成。
