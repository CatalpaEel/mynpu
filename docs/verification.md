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

EGo1 `xc7a35tcsg324-1` 工程已用 Vivado 完成综合、实现和 bitstream 生成，加入 descriptor 防护后的 50 MHz MMCM 时钟实现后 WNS 为 `+1.191 ns`，TNS 和 failing endpoints 均为 0，Vivado DRC error 为 0。实现日志仍有 RAM 异步控制信号的 `REQP-1839` warning；EGo1 已完成无外部 Debug Module 的 VIO 自测，OpenOCD/GDB 真实探针链路仍未联调。

## 全 MNIST 与 AXI 随机压力

2026-10-10 使用 `eeml` conda 环境中的 PyTorch 2.8.0+cpu / torchvision 0.23.0，下载并遍历了 MNIST 完整 10,000 张测试集。`tools/mnist_regression.py` 同时运行 checkpoint 的 FBGEMM INT8 模型和 NPU 的 descriptor/INT8/Q31 整数参考：两者准确率均为 **99.01%**，输入 code 范围为 0..127，整数输出范围为 0..127，只有 4/10,000 张的最终 argmax 不同。这 4 张属于 PyTorch/FBGEMM 与 RTL 半向上 Q31 舍入的边界差异；整数参考与固定镜像的 `tools/build_firmware.py` 结果一致。脚本默认用 seed=14596 选择 64 张样本，并把 NPU 输入/10-byte 输出写入 `build/mnist-regression/`。

这 64 张样本又通过 `sim/tb_cnn_npu_mnist.sv` 逐张写入 NPU 本地 SRAM、启动六层单端口 FPGA BRAM NPU、读回 10 个输出并对整数 golden 比较。VCS 结果为 `[CNN-MNIST] PASS vectors=64 input_bytes=784`，仿真时间为 184,844,250,000 ps。该 testbench 每个样本都走和 CPU 相同的本地 SRAM 总线，不使用 activation backdoor。

上面的 standalone NPU 回归不包含 CPU。为验证真正的 CPU-in-loop 路径，新增 `sw/main_stream.c` 和 `sim/tb_mynpu_soc_stream.sv`：CPU 启动后先通过自己的 AXI 数据口写入参数和 descriptor，写入 READY mailbox；testbench 再通过 JTAG/DMI/SBA 把每张量化输入写进 NPU SRAM，并写入 command mailbox。CPU 轮询 command，启动 NPU，接收 NPU IRQ，清 DONE，读回 10 个 code 并写入 DONE mailbox；下一张输入前 host 与 CPU 继续共享同一个 3×4 crossbar。VCS 已通过 64 张随机样本，日志为 `[SOC-STREAM] PASS CPU-in-loop vectors=64, Debug SBA input injection, CPU AXI model load, NPU IRQ and result readback`，仿真时间为 340,288,760,000 ps（CPU time 489.190 s）。

`sim/tb_axi2mem_backpressure.sv` 对 SoC 使用的 `axi2mem` 做了 1,000 笔随机读写 burst（长度 1..8 个 32-bit beat、随机地址、随机 VALID 空闲间隔），并在每个响应周期独立随机化 `RREADY` 和 `BREADY`。响应数据在同步 SRAM 模型中逐拍检查，VCS 结果为 `[AXI-BP] PASS transactions=1000 randomized RREADY/BREADY every response cycle`，仿真时间为 224,250,000 ps。测试同时检查 RDATA 在 RREADY=0 时保持、ID/RESP/LAST 正确和 byte-enable 写入。

ASIC 主路径还增加了 `sim/tb_mynpu_soc_asic_stress.sv`。它把 CPU 镜像通过真实 JTAG→DMI→SBA 写入 `USE_ASIC_SRAM=1` 的 CPU 宏，把模型和输入由 CPU 写入 NPU 宏，然后执行 3 次完整启动、64 个 NPU SRAM SBA 写读、3 次 CPU halt/resume、非法 layer count 恢复，以及 NPU 运行中的系统复位。每次复位后 testbench 都重新写 `dmactive=1` 并重新加载 CPU 镜像；这是宏没有 `$readmemh` 且 Debug Module 复位会清掉 `dmactive` 时必须的启动动作。该回归在课程 RA1SHD Verilog model 上通过，日志为 `[SOC-ASIC-STRESS] PASS full SoC boots=3, CPU/NPU macro SRAM, SBA=64, halt/resume=3`。运行使用 `+notimingchecks +no_notifier`，所以它是宏功能模型回归，不是 PDK 的 STA/SDF 签核。

## 尚未覆盖、但需要补测的压力项

下面这些场景目前不能标记为通过，且优先级高于继续增加同一模型的重复推理次数：

1. **P0：SBA 忙状态和真实跨模块竞争。** ASIC 回归已强制保持 SBA grant 为低，在 `sbbusy=1` 时再次写 `SBAddress`，检查 `sbbusyerror`、释放请求、W1C 清错并继续访问；同时在 CPU 轮询和 NPU 运行期间执行 128 组随机 Debug mailbox/status 读。还测试了 SBA 请求保持期间的 DMI/AXI 复位。3 次完整启动均通过。还需增加更长的随机 burst 和 starvation 统计，独立 `axi2mem` backpressure 仍不能替代 crossbar 覆盖。
2. **P0：单端口 NPU 的 BUSY 期间主机访问。** ASIC 回归曾捕获本地读返回旧的 `0x00000001`。现在单口 backend 对 BUSY 本地读返回确定的 `0xdead_b001`，并在 `REG_ERROR` 记录该违规；BUSY 本地写保持 AXI 完成但不落 SRAM，同一模型的 3 次 ASIC 启动和 FPGA BRAM SoC 回归均通过。正常驱动仍必须在访问参数、descriptor 和数据前检查 BUSY。
3. **P0：随机相位复位。** ASIC 回归已在 JTAG 活动期间复位一次，并在 NPU 运行期间同时施加随机相位复位和 TCK 活动；复位后重新激活 `dmactive`、重新加载 CPU 镜像，3 次启动通过。仍需扩大随机种子和在每个 AXI response 状态注入复位的次数。
4. **P1：宏接口和 byte-enable。** `sim/tb_mynpu_sram_masks.sv` 已在 FPGA BRAM 和 ASIC RA1SHD model 上遍历 16 种 `WEN[3:0]` 组合、地址 0/1023/2047、连续读写和 byte 保持，均通过。复位前后真实宏未知状态以及 PDK timing corner 仍需门级验证。
5. **P1：量化数值边界。** `sim/tb_cnn_npu_sp_edges.sv` 已在两个 backend 逐元素通过 activation `0/127/255`、weight `-128/127`、`shift=0/63`、`qmax=127/255`、ReLU、非零 zero-point 和奇数 FC 通道。最大 bias/accumulator 溢出、`shift=1/31` 的系统组合和 FBGEMM bit-exact 舍入仍未穷举。
6. **P1：descriptor 和存储边界。** 同一 edge test 已通过 descriptor 恰好剩余 32B 的越界拒绝、8 层合法 FC descriptor 链、3×3 卷积 stride=1 和 3×3→2×2 卷积 stride=2。更大的 FC/卷积混合、奇数 H/W/C、区域重叠策略和每个非法字段的独立恢复路径仍需补测。
7. **P1：IRQ/控制竞态。** `tb_cnn_npu_sp_edges.sv` 已在两个 backend 测试 BUSY 时重复 `START`、DONE 未清除时直接重启、IRQ 保持和 CLEAR；两次完成恰好产生两次 IRQ，CLEAR 后 IRQ 拉低。CPU halt/resume 与真实 CPU handler 已由 SoC 回归覆盖；IRQ enable/disable 与 halt 同周期的更多组合仍需补测。
8. **P2：长时间和物理实现。** `tb_cnn_npu_sp.sv` 已在 FPGA BRAM 和 ASIC RA1SHD model 各连续运行 100 次，均报告 `cycles=288390` 且无状态泄漏。1,000/10,000 次持续推理、cycle counter 接近 32-bit 回绕仍未执行；还需要使用 PDK `.lib/.sdf` 做多 corner 门级仿真、宏 timing check 不加 `+no_notifier` 的回归、以及 STA/IR/EM/CDC/RDC。当前 VCS 宏回归不能替代这些签核。

ASIC 宏回归的基本复现命令如下；`$RA1SHD_V` 必须指向课程压缩包里的私有 `RA1SHD_2048x32M8.v`，该文件不放入公开仓库：

```sh
vcs -full64 -sverilog -assert svaext -timescale=1ns/1ps +define+SYNTHESIS \
  -f sim/soc.f rtl/mynpu_sram_2048x32_asic.sv "$RA1SHD_V" \
  sim/tb_mynpu_soc_asic_stress.sv -top tb_mynpu_soc_asic_stress \
  -pvalue+tb_mynpu_soc_asic_stress.BOOT_ROUNDS=3 \
  -pvalue+tb_mynpu_soc_asic_stress.SBA_WORDS=64 \
  -pvalue+tb_mynpu_soc_asic_stress.HALT_ROUNDS=3 \
  -o build/vcs-asic-stress/simv
build/vcs-asic-stress/simv +notimingchecks +no_notifier +ntb_random_seed=14596
```

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

仍未覆盖多 hart、真实探针下载、OpenOCD/GDB 联调、物理 SRAM 宏的 STA，以及 FBGEMM 的逐元素 bit-exact 复现。上面的 P0/P1/P2 清单是下一批回归的边界；全 MNIST 的 RTL 逐样本回灌可以提高 `--random-vectors`，软件整数参考已经覆盖全部 10,000 张。
