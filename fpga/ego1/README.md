# EGo1 FPGA smoke test

当前另提供 Lab6 外接 FT232H/J5 的两套 4-lane 版本：`build_jtag_private.tcl`（CPU/NPU 独立 SRAM）和 `build_jtag_shared.tcl`（共享双 bank），均经 Boot ROM 等待后由 JTAG 冷加载。完整接线、源码安装 OpenOCD、GDB 操作、PC 连续推理命令见 [Lab6 JTAG 指南](../../docs/lab6-jtag.md)。以下的 USB/VIO 自运行工程仍可使用。

共享 bank 版已于 2026-10-19 完成 [Flash 启动 + 外接 FT232H 实板验证](../../docs/ego1-flash-boot.md)：197 次 CPU-in-loop 推理全部通过，GDB 寄存器/内存访问通过，NPU 每次 35570 周期。独立 SRAM 版的外接探针实测仍待进行。

## 双 8KB 共享 bank、4-lane 版本（USB/VIO 自运行路径）

`feature/dual-bank-shared-sram` 使用完整 CPU/NPU SoC，共享两块逻辑 8KB 单口
BRAM，对应 ASIC 的两块 RA1SHD 宏。CPU 程序、单份模型权重、描述符和激活
已经按物理 bank 放入 `generated/dual-bank/cpu_bank0.hex` / `cpu_bank1.hex`，
CPU 启动后直接使用，不再从固件复制整份模型。默认激活缓存 4B，NPU 为 4 lane。
存储映射、仲裁和 ASIC 加载方式见 [共享 bank 架构](../../docs/shared-bank-npu.md)。

使用板载 USB-JTAG 下载，通过 VIO 读取 CPU mailbox 并发出软复位，不需要
FT232H、杜邦线、OpenOCD 或外接 RISC-V Debug Module 探针：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_autonomous_dual_bank.tcl
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl `
  -log build/ego1-dual-bank-board-20261015.log `
  -journal build/ego1-dual-bank-board-20261015.jou `
  -tclargs --program 20 dual_bank
```

独立工程目录为 `vivado_autonomous_dual_bank`，输出
`build/ego1_autonomous_top_dual_bank.bit/.ltx`，器件为 `xc7a35tcsg324-1`。
2026-10-15 已实际下载并完成 **21 次启动、105 次推理**，每次 class=2、
error=0、IRQ=5、NPU cycles=35570，即 50MHz 下 0.7114ms 的 NPU 计算时间。
每次推理由真实 CPU 检查全部 10 个整数输出码；复位期间检查 mailbox/IRQ 清零。
全部五轮均使用 CPU WFI/IRQ，所以 LED0..3 的最终值为二进制 `0101`。
LED4 心跳、LED5 时钟锁定、LED6 PASS、LED7 FAIL/timeout。

```text
BOARD_SELFTEST PASS round=0 status=c0dec0de irq_edges=5 class=2 cycles=35570
... round=1..19 均相同 ...
BOARD_SELFTEST PASS round=20 status=c0dec0de irq_edges=5 class=2 cycles=35570
BOARD_REGRESSION PASS boots=21 inferences=105
```

最终布线报告：50MHz 约束下 WNS=+1.265ns、WHS=+0.029ns，setup/hold
failing endpoints 均为 0。含完整 SoC、VIO/debug hub：11567 LUT、8745 FF、
17 DSP、4 RAMB36E1。两个 RAMB36E1 组成一块逻辑 8KB bank，总共两块；
这不代表 ASIC 需要四块 SRAM。记录及文件 SHA256 见
[板测记录](../../docs/dual-bank-fpga-board.json)。

板测为固定输入重复回归；64 张不同 MNIST 输入及 ASIC 冷加载属于 VCS
完整 SoC 验证。匹配物理 BRAM 初值且无 SBA 轮询的仿真同样为 35570 周期；
带 SBA mailbox 轮询的 SoC 测试为 35574 周期。此段记录 USB/VIO 自运行测试；
外接 RISC-V DM 的实测另见上面的 Flash/JTAG 记录。

以下保留原独立 CPU/NPU SRAM 的旧版工程与板测说明。

## 原独立 SRAM 自运行版本（旧版基线）

如果没有 FT232H、下载器转接线或杜邦线，使用 `ego1_autonomous_top`。它把
`tck_i/tms_i/td_i` 固定在 TAP 空闲状态，CPU 从 BRAM 自动启动，先把模型参数和
descriptor 写入 NPU BRAM，再完成一轮轮询和四轮中断推理。RISC-V Debug Module
仍随 SoC 内部例化以保持 RTL 统一，但没有外部连接，也不会参与这条测试路径。

板上的 USB-JTAG 配置口只负责下载 bitstream；本版本额外带一个 Vivado VIO，
通过同一个配置口读取 CPU mailbox、IRQ 次数、分类结果和 NPU 周期，并能发出
软复位。因此不需要 OpenOCD、GDB 或 J5 上的 JTAG 杜邦线。

在仓库根目录执行：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_autonomous_bitstream.tcl
```

生成的文件是 `fpga/ego1/build/ego1_autonomous_top.bit` 和同名 `.ltx`。插着
EGo1 的 USB 线时，可直接检测器件：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl
```

下载并让脚本通过 VIO 连续复位三次，每次都等待五轮推理完成：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl -tclargs --program 3
```

成功输出 `BOARD_REGRESSION PASS boots=4 inferences=20`。LED0..3 是 NPU IRQ
边沿计数，完成时为二进制 4；LED4 是心跳，LED5 是 MMCM lock，LED6 是 CPU
mailbox `0xc0dec0de` 的 PASS，LED7 表示 firmware error 或 watchdog timeout。
复位按键是 P15，100 MHz 时钟是 P17。

这个 bitstream 已在本机连接的 `xc7a35tcsg324-1` 上实际下载并验证：4 次
启动、20 次推理均得到 class 2、4 次 IRQ、288390 个 NPU 周期。

### 4-lane 单口向量版本

新 4-lane 使用和 ASIC 相同的 `cnn_npu_sp_lanes` 与四个 MAC 实例，NPU
仍为一块逻辑 8KB 单口 SRAM/BRAM。配套 packed4 CPU 镜像放在
`generated/8k-p4/cpu.hex`，工程目录为 `vivado_autonomous_4lane`，不覆盖原 1-lane 工程。

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_autonomous_4lane.tcl
# 生成 bit/ltx 后，可用同一个板载 USB-JTAG/VIO 路径下载和复位回归：
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl -tclargs --program 3 4lane
```

输出为 `fpga/ego1/build/ego1_autonomous_top_4lane.bit/.ltx`。4-lane VCS
BRAM/ASIC 回归测得 65732 cycles；实际下载结果与 FPGA 时序报告单独记录，
不能把上面旧 1-lane 的板上 PASS 当作新 4-lane 的上板证据。

2026-10-12 已使用 Vivado 2023.2 重新生成包含 ERROR→START 修复的 4-lane
bitstream。50MHz 约束下 WNS=+1.036ns、WHS=+0.028ns，TNS/THS 和 failing
endpoints 均为 0，bitgen DRC error=0。完整 SoC（含 VIO/debug hub）使用
12385 LUT、9030 FF、17 DSP、4 RAMB36。独立 NPU 综合另检查到四个
`cnn_npu_lane_mac` 实例，占 2909 LUT、1302 FF、12 DSP、2 RAMB36；这些
是 FPGA 资源，不能据此估计 ASIC 面积或频率。

2026-10-12 的 Hardware Manager 曾未检测到板卡。2026-10-13 接入 EGo1
后，已实际下载上述 4-lane bitstream，并执行一次初始启动和 20 次 VIO
软复位，**21 次启动、105 次六层推理全部通过**。每次 mailbox 为
`0xc0dec0de`、error=0、class=2、IRQ edges=4、NPU cycles=65732。
每次启动的第一轮用轮询，后四轮由真实 CPU ISR 完成；CPU 每轮重新写
输入并严格检查全部 10 个输出 code，另检查与 PyTorch code 的差值 ≤1。
复位保持期间还检查 mailbox/IRQ 观察值归零。

这次使用固定自测输入，属于实体板上的重复启动/推理回归；64 张不同
MNIST 的 CPU-in-loop 记录仍属于 VCS 仿真。下载和观测都经板载 USB-JTAG
与 VIO，外部 RISC-V Debug Module 链路没有参与，不需要 FT232H 或杜邦线。
完整本机日志为 `build/ego1-4lane-board-20261013.log`，复现命令：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl `
  -log build/ego1-4lane-board-20261013.log `
  -journal build/ego1-4lane-board-20261013.jou `
  -tclargs --program 20 4lane
```

```text
BOARD_SELFTEST PASS round=0 status=c0dec0de irq_edges=4 class=2 cycles=65732
... round=1..19 均相同 ...
BOARD_SELFTEST PASS round=20 status=c0dec0de irq_edges=4 class=2 cycles=65732
BOARD_REGRESSION PASS boots=21 inferences=105
```

### 8-lane 参数实验（旧版上板记录）

可以用 `fpga/ego1/build_autonomous_8lane.tcl` 生成并下载带
`NPU_LANES=8` 的独立 bitstream：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_autonomous_8lane.tcl
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl -tclargs --program 3 8lane
```

之前上板的 8-lane 参数 bitstream 使用旧串行核心，实际为 288390 cycles。
当前 RTL 已增加真正的向量核心；重新运行 8-lane 脚本会走 legacy OIHW
兼容预取路径，不再代表旧 bitstream。推荐先用上面的 4-lane packed4
工程；ASIC 的 8-lane packed4 NPU 功能回归为 55723 cycles，尚未以该
配置替代 4-lane 的完整 SoC/上板主回归。

## Lab 6 外部 JTAG 版本（旧版说明）

旧 1-lane 预置程序工程已由上述 4-lane 冷加载工程替代。`create_project.tcl` 现在默认创建 private JTAG 工程，`build_bitstream.tcl` 默认转入 `build_jtag_private.tcl`。以新的 [Lab6 指南](../../docs/lab6-jtag.md)为准；下述为历史配置说明。

This shell targets the XC7A35T EGo1 board. The board clock is 100 MHz on P17;
the reset and LED pins are from the EGo1 V2.2 manual. Check the board revision
and reset polarity before programming. The shell sets `LANES=1`, preloads the
8KB CPU image, and uses synchronous inferred BRAM for both CPU and NPU SRAM.
The NPU is the `LANES=1` single-port schedule, matching the storage timing
used by the FPGA integration smoke test.

From the repository root, run `vivado -mode batch -source
fpga/ego1/create_project.tcl`, then
`vivado -mode batch -source fpga/ego1/build_bitstream.tcl`. The scripts create
the `xc7a35tcsg324-1` project, add the RTL in `sim/soc.f`, copy the CPU hex,
set `ego1_soc_top` as top, and generate
`fpga/ego1/build/ego1_soc_top.bit`. The top uses an MMCM to make 50 MHz from
the P17 100 MHz oscillator and synchronously releases reset after `locked`.

LED0 is MMCM locked, LED1 is the heartbeat, LED2 is the NPU interrupt, LED3 is
CPU debug-halted, and LED4 changes when external TCK activity arrives. The
board's USB configuration JTAG does not drive the RISC-V Debug Module. Wire an
external FT232H adapter to J5 as described in `ego1_openocd.cfg`, start
OpenOCD, and connect RISC-V GDB to port 3333.

## Lab 6 host setup

Open an **Administrator PowerShell** window in the repository and attach the
external FT232H after plugging it in:

```powershell
.\fpga\ego1\attach_ft232h.ps1
```

The script only accepts VID:PID `0403:6014`, binds the adapter with
`usbipd-win`, and attaches it to the default WSL distribution. In Ubuntu WSL,
verify that it is visible and install the Linux tools if this is a new distro:

```bash
lsusb | grep 0403:6014
bash fpga/ego1/setup_wsl.sh
bash fpga/ego1/start_openocd.sh
```

In a second WSL terminal, use `bash fpga/ego1/start_gdb.sh` and run
`target remote :3333`. The supplied config uses the command names supported by
Ubuntu OpenOCD 0.12. The FPGA RTL does not need an OpenOCD-specific change:
the current top already exposes the Lab 6 `tck_i/tms_i/td_i/td_o` pins to the
Debug Module. The USB-JTAG port used by Vivado only programs the bitstream;
the FT232H/J5 wiring is the separate RISC-V JTAG path.
