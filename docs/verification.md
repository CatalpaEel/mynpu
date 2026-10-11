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

压力回归将 `tb_mynpu_soc` 的 `STRESS_MODE` 设为 1，额外执行复位脉冲、64/128/256 个连续 SBA SRAM 写读、非法 layer count、越界 descriptor base、以及 NPU 运行期间 CPU Debug halt/resume。VCS 已通过以下组合：8KB/LANES=8（64 个 SBA word、3 次 halt/resume，周期 10704）、8KB/LANES=1（256 个 SBA word、5 次 halt/resume，周期 54132）、16KB/LANES=16（128 个 SBA word、5 次 halt/resume，周期 9882）。单口 FPGA NPU 的独立 testbench 也会检查非法配置进入 ERROR、控制清错后回到 IDLE，再连续执行五轮推理。

这次压力测试发现并修复了一个错误恢复问题：原先 NPU 进入 `ERROR` 后，控制寄存器清除 `error_q`，但 `S_ERROR/ERROR` 状态仍在每个周期重新置位错误，导致后续合法 START 不能恢复。现在清错请求在空闲错误状态下同时将状态机退回 `IDLE`，且 sticky-error 逻辑不会覆盖同周期的清除操作。

EGo1 `xc7a35tcsg324-1` 工程已用 Vivado 完成综合、实现和 bitstream 生成，加入 descriptor 防护后的 50 MHz MMCM 时钟实现后 WNS 为 `+1.191 ns`，TNS 和 failing endpoints 均为 0，Vivado DRC error 为 0。实现日志仍有 RAM 异步控制信号的 `REQP-1839` warning；上板时需要观察复位期间 BRAM 内容和启动行为。尚未连接真实 EGo1、FT232H 探针并完成 bitstream 下载与 OpenOCD/GDB 联调。

## 全 MNIST 与 AXI 随机压力

2026-10-10 使用 `eeml` conda 环境中的 PyTorch 2.8.0+cpu / torchvision 0.23.0，下载并遍历了 MNIST 完整 10,000 张测试集。`tools/mnist_regression.py` 同时运行 checkpoint 的 FBGEMM INT8 模型和 NPU 的 descriptor/INT8/Q31 整数参考：两者准确率均为 **99.01%**，输入 code 范围为 0..127，整数输出范围为 0..127，只有 4/10,000 张的最终 argmax 不同。这 4 张属于 PyTorch/FBGEMM 与 RTL 半向上 Q31 舍入的边界差异；整数参考与固定镜像的 `tools/build_firmware.py` 结果一致。脚本默认用 seed=14596 选择 64 张样本，并把 NPU 输入/10-byte 输出写入 `build/mnist-regression/`。

这 64 张样本又通过 `sim/tb_cnn_npu_mnist.sv` 逐张写入 NPU 本地 SRAM、启动六层单端口 FPGA BRAM NPU、读回 10 个输出并对整数 golden 比较。VCS 结果为 `[CNN-MNIST] PASS vectors=64 input_bytes=784`，仿真时间为 184,844,250,000 ps。该 testbench 每个样本都走和 CPU 相同的本地 SRAM 总线，不使用 activation backdoor。

上面的 standalone NPU 回归不包含 CPU。为验证真正的 CPU-in-loop 路径，新增 `sw/main_stream.c` 和 `sim/tb_mynpu_soc_stream.sv`：CPU 启动后先通过自己的 AXI 数据口写入参数和 descriptor，写入 READY mailbox；testbench 再通过 JTAG/DMI/SBA 把每张量化输入写进 NPU SRAM，并写入 command mailbox。CPU 轮询 command，启动 NPU，接收 NPU IRQ，清 DONE，读回 10 个 code 并写入 DONE mailbox；下一张输入前 host 与 CPU 继续共享同一个 3×4 crossbar。VCS 已通过 64 张随机样本，日志为 `[SOC-STREAM] PASS CPU-in-loop vectors=64, Debug SBA input injection, CPU AXI model load, NPU IRQ and result readback`，仿真时间为 340,288,760,000 ps（CPU time 489.190 s）。

`sim/tb_axi2mem_backpressure.sv` 对 SoC 使用的 `axi2mem` 做了 1,000 笔随机读写 burst（长度 1..8 个 32-bit beat、随机地址、随机 VALID 空闲间隔），并在每个响应周期独立随机化 `RREADY` 和 `BREADY`。响应数据在同步 SRAM 模型中逐拍检查，VCS 结果为 `[AXI-BP] PASS transactions=1000 randomized RREADY/BREADY every response cycle`，仿真时间为 224,250,000 ps。测试同时检查 RDATA 在 RREADY=0 时保持、ID/RESP/LAST 正确和 byte-enable 写入。

复现命令（需要能运行 VCS 的 Linux 主机）：

```sh
conda run -n eeml python tools/mnist_regression.py --layout 8k --random-vectors 64
python tools/build_stream_firmware.py --runs 1000
vcs -full64 -sverilog -assert svaext -timescale=1ns/1ps +define+SYNTHESIS \\
  -f sim/soc.f sim/tb_mynpu_soc_stream.sv -top tb_mynpu_soc_stream \\
  -pvalue+tb_mynpu_soc_stream.VECTORS=64 -o build/vcs-soc-stream/simv
build/vcs-soc-stream/simv
vcs -full64 -sverilog -timescale=1ns/1ps \
  rtl/mynpu_sram_2048x32_fpga.sv cnn_npu_int8/rtl/cnn_npu_sp_top.sv \
  sim/tb_cnn_npu_mnist.sv -top tb_cnn_npu_mnist \
  -pvalue+tb_cnn_npu_mnist.VECTORS=64 -o build/vcs-cnn-mnist/simv
build/vcs-cnn-mnist/simv

vcs -full64 -sverilog -assert svaext -timescale=1ns/1ps \
  +incdir+third_party/lab3/soc/rtl/include +incdir+third_party/lab3/soc/rtl \
  third_party/lab3/soc/rtl/axi/axi_pkg.sv \
  third_party/lab3/soc/rtl/axi/axi_intf.sv \
  third_party/lab3/soc/rtl/axi/axi2mem.sv \
  sim/tb_axi2mem_backpressure.sv -top tb_axi2mem_backpressure \
  -pvalue+tb_axi2mem_backpressure.TRANSACTIONS=1000 -o build/vcs-axi-bp/simv
build/vcs-axi-bp/simv +ntb_random_seed=14596
```

仍未覆盖多 hart、真实探针下载、OpenOCD/GDB 联调、物理 SRAM 宏的 STA，以及 FBGEMM 的逐元素 bit-exact 复现。全 MNIST 的 RTL 逐样本回灌可以提高 `--random-vectors`；软件整数参考已经覆盖全部 10,000 张。
