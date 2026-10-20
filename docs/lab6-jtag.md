# EGo1：按 Lab6 使用外接 FT232H、OpenOCD、GDB

这套工程沿用用户提供的 Lab6 通路：EGo1 Type-C 接 Vivado 配置 FPGA；外接 FT232H 经六根线接 J5，访问 SoC 内的 RISC-V DTM/Debug Module；Ubuntu WSL 运行 OpenOCD 与 GDB。两条 JTAG 链独立；直接下载 `.bit`、由电脑给板子供电时，需要两条 USB 连接。

电脑只有一个 USB-A 口时，可以先把 FPGA 配置烧入板载 Flash，以后用 USB 充电头给开发板
供电，把电脑 USB-A 留给外部 FT232H。接线、两版 Flash 镜像和烧写脚本见
[Flash 上电启动指南](ego1-flash-boot.md)。运行阶段无需把板载配置 USB 连接电脑；CPU/模型/输入仍由 DM 加载。

| 配置名 | 存储与总线 | FPGA 构建入口 | 输出 bitstream |
|---|---|---|---|
| `private` | CPU/NPU 各 8KB 单口，3×4 crossbar，4 lane | `build_jtag_private.tcl` | `ego1_jtag_private.bit` |
| `shared` | CPU/NPU 共用两个 8KB 单口 bank，3×3 crossbar，4 lane | `build_jtag_shared.tcl` | `ego1_jtag_shared.bit` |

两套工程共用 `ego1_soc_top.sv`、`ego1.xdc` 和 PC 工具，通过参数选择布局。工程目录分别为 `fpga/ego1/vivado_jtag_private`、`vivado_jtag_shared`，器件均为 `xc7a35tcsg324-1`。原有 USB/VIO 自运行工程仍保留。

## 1. 时钟、复位和 ASIC 冷加载

P17 的 100MHz 经 `MMCME2_BASE` 与 BUFG 生成 50MHz，等 MMCM locked 后两级同步释放复位。它实现 Lab6 Clocking Wizard 对应的 MMCM 时钟功能，不使用触发器翻转分频。P15 为低有效复位输入；沿用已验证的板级极性。

新增 `mynpu_soc_top.JTAG_BOOT_CONTROL=1`，ASIC/FPGA 使用相同 Boot ROM 与启动控制逻辑。FPGA 不预装 CPU 固件或 NPU 模型。上电后 CPU 执行 ROM 等待循环，可以被 OpenOCD/GDB halt，不会取未加载的 SRAM 指令。

| 地址 | 含义 |
|---|---|
| `0x00010000..0x00010017` | ROM 等待 RUN，随后跳转 `0x80000000`；代码只读 |
| `0x00010030` | RUN bit0，复位为 0，加载完后写 1 |
| `0x00010034` | 版本 ID：private/4 lane=`0x4a541004`；shared/4 lane=`0x4a541104` |
| `0x00010038` | 激活缓存 word 数：private=0，shared 默认=1 |

这几个字使用原来的 64B Boot 地址窗口，不增加 crossbar 请求入口或目标出口。`boot_ready_i` 在板级接 1；CPU 在 ROM 内等待 RUN。ASIC 若启用同一模式，外部也应在时钟稳定后允许 CPU 进入 ROM。

RUN 只负责启动等待，不是 CPU 停机信号。重装固件应执行 `mynpu_reset`，它通过 DM 的 `ndmreset` 复位 CPU、NPU、总线及 RUN，保留调试模块，然后让 CPU 停在 ROM。加载完成后 `mynpu_run` 释放 RUN 并请求 CPU resume。主板复位会连 DM/TAP 一起复位；按 Lab6 指南，应重启 OpenOCD、重新连接并重新加载。

`JTAG_BOOT_CONTROL` 默认仍为 0，原自运行固件/Boot RAM 行为保持兼容。不修改 `third_party/lab3`。

## 2. Vivado 创建与构建工程

仓库位于纯英文、无空格的路径。在仓库根目录的 PowerShell 执行：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch -source fpga/ego1/build_jtag_private.tcl
& E:\Vivado\2023.2\bin\vivado.bat -mode batch -source fpga/ego1/build_jtag_shared.tcl
```

脚本重新创建独立工程，添加 `sim/soc.f`、板级顶层与 XDC，依次综合、实现、生成 bitstream，并输出时序/资源报告。50MHz 的 setup 或 hold slack 为负时，脚本报错。报告位于 `fpga/ego1/build/ego1_jtag_<布局>_timing.rpt` 和 `_utilization.rpt`。没有 CPU/NPU `$readmemh` 初始化是此冷加载版本的预期行为；两块单口 BRAM 都必须保留。

`::JTAG_NPU_LANES`、`::JTAG_CACHE_WORDS` 可在 Tcl 中覆盖，默认 4、1。调整后同时重建匹配的 PC manifest/固件；默认资产为 4 lane。ASIC 两个 SRAM 仍各 8KB，FPGA 对应四个 RAMB36E1，不使用 FPGA 多端口放宽 ASIC 的单口限制。

## 3. 烧写 FPGA 与接线

EGo1 Type-C 线接电脑并上电。先选一个版本下载：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_jtag.tcl -tclargs private
# 共享 bank 版：把最后一个参数改为 shared
```

这个步骤只配置 FPGA；CPU 应停在 ROM 等待，不会自动开始 MNIST 自测。LED0=MMCM locked、LED1=心跳、LED2=NPU IRQ、LED3=CPU debug halted、LED4=TCK 活动，LED5..7 未使用。原 VIO 自运行版的 PASS/IRQ LED 定义不适用于本工程。

以下接线沿用 Lab6 §8.2 与现有 EGo1 约束，接线时核对板卡版本/J5 编号：

| FT232H 下载器信号 | EGo1 J5 | FPGA 管脚 |
|---|---|---|
| TCK | 17 | E15 |
| TDI（下载器输出） | 18 | E16 / SoC `td_i` |
| TDO（下载器输入） | 19 | D15 / SoC `td_o` |
| TMS | 20 | C15 |
| VREF | 35 或 36，3.3V | 电平参考 |
| GND | 33 或 34 | 共地 |

VREF 作为参考输入，不给开发板供电。XDC 使用 LVCMOS33，TCK 约束为 1MHz，与包含 MMCM 输出的系统时钟组异步。OpenOCD 初始只跑 Lab6 推荐的 10kHz。

## 4. PC 环境：按 Lab6 源码安装 OpenOCD

本机已有 Ubuntu WSL2、usbipd-win、GDB Multiarch、Python3 和 RISC-V GCC。另提供按 Lab6 §9.2 编译 RISC-V OpenOCD 的脚本，固定源码 revision，安装至 `/usr/local`；保留发行版 OpenOCD 作为兼容备选。

在仓库根目录的 PowerShell 执行：

```powershell
wsl -d Ubuntu -u root -- bash -lc `
  'cd /mnt/c/Users/zhujunan/Desktop/tapeout/mynpu && bash fpga/ego1/setup_lab6_openocd.sh'
```

已固定源码 `riscv/riscv-openocd` revision `10b7a647da03cb64fd25db76261712c388ad6468`。使用 `--enable-ftdi` 编译；安装后 `which openocd` 应优先得到 `/usr/local/bin/openocd`。`setup_wsl.sh` 保留为只安装发行版工具的简便备选。

本机已完成源码编译安装，版本为 `0.12.0+dev-04406-g10b7a647d`。GDB Multiarch 已离线载入两版 RV32 ELF/符号，PC 六项协议/异常测试和 Tcl SBA 错误/超时检查均通过；这些软件检查不代替实体下载器联调。

先打开 Ubuntu WSL 终端并保持窗口运行（仅执行一次短命令后退出，WSL 可能自动停止）。
再用 Windows 管理员 PowerShell 把 FT232H 交给 WSL；首次 `usbipd bind` 需要管理员权限：

```powershell
usbipd list
.\fpga\ego1\attach_ft232h.ps1
```

只选择 `0403:6014` 的外接 FT232H。脚本检查 VID/PID，随后 bind/attach。不要把 EGo1 配置线缆当作这个外接下载器。插拔或重启后重新 attach。在 Ubuntu WSL 中确认：

```bash
lsusb
cd /mnt/c/Users/zhujunan/Desktop/tapeout/mynpu
sudo bash fpga/ego1/start_openocd.sh
```

`ego1_openocd.cfg` 沿用 Lab6 的 FTDI VID/PID、channel0、layout、IR 长度 5、10kHz、timeout120s、`progbuf sysbus abstract` 优先级、init/halt。它兼容新版 `gdb report_*` 和旧版 `gdb_report_*` 命令。连接后应看到 IDCODE=`0x00000001`、RV32 核以及 GDB 3333/Tcl 6666 服务。脚本加载 `sba_helpers.tcl` 提供冷加载操作。若使用其他安装路径，可设置 `OPENOCD=/路径/openocd`。

## 5. GDB 手动调试：Lab6 主流程

保持 OpenOCD 终端运行，另开 Ubuntu WSL 终端，在仓库根目录执行：

```bash
bash fpga/ego1/debug_cpu.sh private
# 共享版使用 shared
```

脚本把已发布 hex 转换成本机 `build/jtag/<布局>/` 下的二进制，生成 GDB 加载文件，并启动 GDB Multiarch（支持 RV32）。若本机重编译过固件，还会加载 ELF 符号。依次执行连接、DM 复位/halt、版本校验、SBA 加载固件与模型、清 mailbox、设置 PC 和 RUN。随后在 `(gdb)` 中输入：

```text
info registers
x/6i $pc
x/8xw 0x80000000
continue
```

稍后 Ctrl+C，检查 CPU 已发布 READY：

```text
x/16xw 0x80001fc0
```

第一个字应为 `0x5354524d`。加载第一张量化输入并执行：

```text
source build/jtag/private/first-input.gdb
```

共享版对应 `build/jtag/shared/first-input.gdb`。脚本要求 READY，再写输入及 sequence0 命令，随后 continue。稍后 Ctrl+C，再执行 `x/16xw 0x80001fc0`；完成标志应为 `0x444f0000`，不是旧 Lab3 的 magic 地址。十个输出码的预期值见同目录 `first-expected.json`。不要把内联注释放到 GDB 的地址/表达式命令后。

## 6. PC 自动连续推理

退出 GDB，让 OpenOCD 保持运行；避免 GDB 同时 halt 干扰 CPU。另一个 Ubuntu 终端运行：

```bash
# 首次接线先做短测试
python3 tools/jtag_host.py --layout private --boots 1 --runs 5
# 稳定后：三个重新加载启动，每次 64 张不同 MNIST 输入
python3 tools/jtag_host.py --layout private --boots 3 --runs 64
# 下载 shared bitstream 后运行
python3 tools/jtag_host.py --layout shared --boots 3 --runs 64
```

PC 自动化使用同一 OpenOCD 的 Tcl RPC 6666 端口和原 DM SBA，不增加板级接口，不用 UART/SPI 或额外 AXI master。GDB 3333 端口仍可用于手动调试。

每次启动先校验布局/lane/cache ID，然后加载、逐字读回核对 CPU/模型镜像，清 mailbox，再释放 CPU。每张图像写入 784B 已量化输入，写 mailbox 命令，由 CPU 发 NPU START、WFI、服务 IRQ、读十个输出码并发布 DONE。PC 检查全部输出严格等于独立整数参考、与实际 PyTorch INT8 输出的差值不超过已导出的 1，以及 argmax、错误状态、非零周期、递增 IRQ 计数。不同图像按 DONE 握手串行提交，不会在 NPU 尚未完成时覆盖输入。

默认 64 张图像来自原 MNIST 随机子集，固定 seed14596；超过 64 次会循环输入，sequence/IRQ 继续递增。单次启动允许 1..65535 次推理。10kHz 下加载与读回会耗费较长时间；日志的 `cycles/50MHz` 才是 NPU 计算时间，USB/JTAG 传输及轮询时间另计。结果写入 `build/jtag/board-<布局>.json`，错误也会写入 JSON 并以非零状态退出。

## 7. 数据布局与复现

| 内容 | private | shared |
|---|---|---|
| CPU 固件 | `0x80000000`，占用不超过 2KB | 同左，bank0 前 2KB |
| 模型装载窗口 | `0x70004000` 起 8192B | `0x70005000` 起 9216B |
| 本次输入/最终输出 | `0x70005400` | `0x70006800` |
| mailbox | `0x80001fc0..0x80001fff` | 同左，bank0 |

shared 的装载长度包含布局空洞和激活空间，权重参数仍只有一份 4288B，不复制到两 bank。每版 manifest 包含下载地址、固件/模型 SHA256 和硬件 ID；不能跨版混用。

mailbox 的 16 个 32-bit word：word0=状态/命令；1=错误码；2=argmax；3=NPU周期；4..13=十个输出码；14=IRQ计数；15=固件版本 ID。sequence 命令为 `0x53540000+seq`，完成为 `0x444f0000+seq`，错误为 `0xdeadbeef`。

资产已发布到 `generated/jtag`，运行测试不需要重装 PyTorch、重编译固件或运行浮点量化。修改 CPU 固件后，可在 WSL 用已有工具链重建：

```bash
python3 tools/build_jtag_assets.py --gcc ../riscv-tool/usr/bin/riscv64-unknown-elf-gcc
```

更换输入子集或参考模型时，在 eeml 环境运行 `tools/build_jtag_vectors.py`；它直接把同一份量化输入码送入真实 PyTorch INT8 模型，并记录输出。CPU/芯片没有浮点到 INT8 的量化步骤。

## 8. 本次构建与测试记录

2026-10-17 两套 bitstream 均已生成，时序/资源摘要如下。两版都是完整 SoC、4 lane、两个逻辑 8KB 单口存储；没有 VIO 自运行 IP。

| 布局 | 50MHz WNS | WHS | LUT | FF | DSP | RAMB36E1 |
|---|---:|---:|---:|---:|---:|---:|
| private | +1.047ns | +0.043ns | 11189 | 6452 | 17 | 4 |
| shared | +1.136ns | +0.040ns | 10547 | 6489 | 17 | 4 |

setup/hold failing endpoints 均为 0。bitstream 与报告 SHA256 见 [FPGA 构建记录](lab6-jtag-fpga.json)。这些是 FPGA 实现结果，不能作为 ASIC 面积、频率、功耗或物理签核结论。

clab VCS 四态完整 SoC 回归已全部通过：

| 布局 | 存储后端 | 启动/重装次数 | 推理次数 |
|---|---|---:|---:|
| private | FPGA 同步单口 BRAM | 3 | 192 |
| shared | FPGA 同步单口 BRAM | 3 | 192 |
| private | ASIC 私有 RA1SHD 宏模型 | 3 | 192 |
| shared | ASIC 私有 RA1SHD 宏模型 | 3 | 192 |

合计 **12 次启动、768 次完整推理**，每次检查全部十个整数输出码、与实际 PyTorch 输出码差值 ≤1、argmax、错误状态、周期和 IRQ 计数。覆盖 ROM 等待期间禁止取 SRAM 指令、真实 TAP/DMI/SBA 加载、只读 ROM/版本 ID、CPU halt/resume/WFI/IRQ、POR/ndmreset 后重新加载。日志摘要和源码 SHA256 见 [VCS 验证记录](lab6-jtag-verification.json)。ASIC 功能仿真禁用 timing check/notifier，未做 PDK 签核。

本地 Verilator 另完成 private/BRAM 的三次启动、192 次推理，作为辅助两态检查；主要仿真结论以四态 VCS 为准。

2026-10-19 实体 **shared / 4-lane** 已完成 Flash 烧写/读回、QSPI 上电启动、外接 FT232H/J5/OpenOCD 冷加载，5 次短测试加 3×64 次连续推理，共 197 次真实 CPU/NPU 推理全部通过。64 张不同输入的十个输出码与整数参考完全一致、PyTorch 最大码差 1，IRQ 计数正确；每次 NPU 为 35570 周期。GDB 寄存器和内存读取也已实测。前 5 次用 10kHz，192 次用 100kHz JTAG；SoC 始终 50MHz。步骤见 [Flash 指南](ego1-flash-boot.md)，完整实板状态见 [板测记录](ego1-flash-board.json)。private 的外接探针实测仍待进行；原 VIO 测试和 VCS 数据分别保留。

可用 `python3 tools/package_jtag_kit.py` 生成 `build/lab6-jtag-kit.zip`：包含两套已校验 bitstream、报告、PC 脚本、固件/模型/64 张参考向量及 ELF 符号。运行包不含私有 SRAM 模型或 PDK 文件；完整 RTL/重建工程保存在 GitHub 分支中。软件与夹具协议测试不需要 PyTorch，只有重新生成 PyTorch 参考时使用 eeml 环境。

功能验证命令：

```bash
python3 sim/test_jtag_host.py
tclsh sim/test_sba_helpers.tcl
python3 tools/run_jtag_sim.py --backend vcs --memory fpga --layout private --vectors 64 --boots 3
python3 tools/run_jtag_sim.py --backend vcs --memory fpga --layout shared --vectors 64 --boots 3
# ASIC 同样运行两版，--memory asic --macro-model /私有路径/RA1SHD_2048x32M8.v
# 不公开宏、不做 timing check/PDK 签核。
```

VCS 是完整四态回归的主工具。本机 XSIM 可选 `--backend xsim`，通过编译宏跳过导入代码中不支持的断言，原 lab3 文件不变；整 SoC 的 JTAG 扫描资源消耗较大，本次本地尝试未作为 PASS 记录。实体 FT232H/J5/OpenOCD 链路的联调状态与 bitstream/功能仿真分开记录，不能把原 USB/VIO 板测当作本版外接探针实测。

OpenOCD 接口参考：[RISC-V DMI/SBA 命令](https://openocd.org/doc/html/Architecture-and-Core-Commands.html)、[Tcl RPC](https://openocd.org/doc/html/Tcl-Scripting-API.html)。本工程的接线和操作顺序以用户提供的 Lab6 指南为依据。
