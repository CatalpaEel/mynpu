# 集成接口与后续实现边界

## 当前完整 SoC 的连接

三个 AXI 请求入口分别来自 CPU 取指、CPU 数据访问、Debug Module SBA。四个目标分别是 Boot RAM、CPU SRAM、NPU 和 Debug Module 的执行窗口。AXI 数据/地址宽度都是 32 bit；请求入口 ID 为 2 bit，crossbar 在目标侧加入来源标识后为 4 bit。NPU 本地访存不经过 crossbar。

新顶层修正了原集成中 adapter 的 AXI ID 宽度，并将 AXI B 写响应反馈给 Debug Module 的 SBA 完成接口，否则 SBA 写操作可能一直处于 busy。源代码均在新增顶层修正；`third_party/lab3` 的 206 个文件保持原始字节，`SOURCE_MANIFEST.json` 可用于核对。

POR `rst_ni` 复位 TAP、Debug Module 和 Boot RAM；DM 的 `ndmreset` 经 rstgen 复位 CPU、crossbar、CPU SRAM 接口和 NPU。CPU SRAM 内容不会被系统复位清除。CPU 的 `boot_ready_i` 只用于控制取指使能；Debug Module 在 CPU 未启动时仍可进行 SBA 访问。

## 外部 JTAG 与软件运行

芯片逻辑端口是 `clk_i/rst_ni/boot_ready_i/tck_i/tms_i/td_i/td_o`，另有 NPU IRQ 和 CPU debug-halted 的观察输出。实际芯片需根据 pad、电源、复位、时钟和启动方案形成 pad 顶层。

DTM 的 IR 是 5 bit，DMIACCESS 指令为 `0x11`，DMI DR 是 41 bit，包含 7 bit 地址、32 bit 数据、2 bit 操作。当前默认 IDCODE 是 `0x00000001`，还不是正式产品标识。测试覆盖 dmcontrol、dmstatus、abstractcs/command、data0、sbcs/sbaddress0/sbdata0。

启动流程可以是：保持 `boot_ready_i=0` → JTAG 激活 DM → 通过 SBA 将固件写入 `0x80000000` → 置 `boot_ready_i=1`。Boot RAM 跳转到 SRAM 中的 `_start`。固件通过 `0x70004000` 窗口加载模型和输入、配置 descriptor 地址与层数、发 START、轮询或等待 IRQ、读输出。

ASIC SoC testbench 不预置宏内容，而是通过 JTAG→DMI→SBA 装载整段 CPU 固件；每次复位后重新设置 `dmactive=1` 并重装固件。FPGA BRAM 自运行路径使用 CPU hex 初始化。真实 OpenOCD/外部探针和 FPGA BSCAN→RISC-V TAP 桥仍未联调；板载配置 JTAG 不会自动连接逻辑中的 RISC-V TAP。EGo1 自运行版本用配置 JTAG 下载 bitstream，并通过 VIO 检查 CPU mailbox，无需外部 Debug 探针。

## NPU 本地存储规划

| 区域 | 8KB NPU | 16KB NPU |
|---|---|---|
| 权重、bias、multiplier、shift | 原 `8k` 为 3984B；向量 `8k-p4` 为 4288B | 原 `16k` 为 3984B |
| Activation A | `0x1400`，到 B 前预留 1536B | `0x2000`，预留 2048B |
| Activation B | `0x1a00`，到 descriptor 前预留 512B | `0x2800`，预留 2048B |
| Descriptor | `0x1c00`，6×36=216B | `0x3000`，216B |

本模型 A 最大使用 784B、B 最大使用 392B，最大同时有效激活量为 1176B。每层通过 descriptor 指定输入和输出地址，在 A/B 之间交替。存储偏移、形状、zero-point、qmax 由 descriptor 决定，通道并行数由 RTL 参数决定。改变模型后须重新计算地址和峰值活跃量，确保区域不重叠。

BUSY 期间主机不应写 NPU 参数、描述符或数据。单口 backend 对违规本地写保持 AXI 完成但不修改 SRAM，并在 `REG_ERROR` 返回 `0xdead_b001`；违规本地读也返回该确定标记，避免把上一次 SRAM/状态数据误当成读结果。它没有等待空闲的 backpressure，正常驱动仍应先检查 BUSY。CPU 读本地数组在 BUSY 期间同样属于违规访问。

## FPGA 与 0.18µm 后续工作

功能数组保留作算法基线；单口向量核心已经实现同步端口、读延迟、packed4 权重读取、activation 广播、word cache 与通道组参数缓存。4-lane ASIC 和 FPGA 功能回归均为 65732 cycles，原 1-lane 为 288390。输出仍按 CHW 逐 byte 写回，requant 共享一个乘法器，详见 [单口向量 NPU](npu-single-port-vector.md)。

如果最终只用两个 8KB 宏，逻辑布局可以继续采用 CPU 8KB + NPU 8KB，但 NPU 宏带宽需通过分拍或 bank/cache 解决。如果要求 CPU/NPU 共用同一物理存储，还需统一地址空间、仲裁取指/数据/NPU请求，并重新安排程序、模型和激活区域；这项尚未实现。

向量核心已把本地 base 收窄到 13 bit、形状和主要循环计数器到 8 bit。完整 uint8 code 减任意 uint8 zero-point 使用 signed 9 bit，INT8 权重乘积为 signed 17 bit，累加为 32 bit；Q31 requant 共享 32×32→64 bit 乘法器并分三个阶段执行。

descriptor 校验覆盖形状非零、flags、存储范围、packed4 对齐和填充容量；主机仍须提供不破坏参数/输入的区域规划。周期已在真实单口宏功能模型上测量，频率/面积则不能由功能仿真或 FPGA 报告推定。本任务按约定只做 RTL/功能模型验证，不执行真实宏 timing check/PDK 签核。
