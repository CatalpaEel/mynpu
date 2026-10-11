# EGo1 FPGA smoke test

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
