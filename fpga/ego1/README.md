# EGo1 FPGA smoke test

## 无 Debug Module 自运行版本（当前上板路径）

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

## Lab 6 外部 JTAG 版本

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
