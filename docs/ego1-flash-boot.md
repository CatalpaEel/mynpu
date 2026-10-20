# EGo1：Flash 启动，电脑只占一个 USB-A 口

适用于本仓库 Lab6 外接 JTAG 的 `private` / `shared` 两套 4-lane 完整 SoC。
先临时用板载 USB-JTAG 把 FPGA 配置写进板载 Flash；以后开发板用 USB 充电头供电，
电脑唯一的 USB-A 口接外部 FT232H。CPU 固件、模型和输入仍通过 Debug Module 加载。

```text
USB 充电头（5V） ── 原开发板 USB 线 ── EGo1 Type-C（供电）
                                             │
                                  板载 Flash → FPGA 配置引擎
                                             │
电脑 USB-A ── USB-A/USB-C 数据线 ── FT232H ── J5 ── DTM / Debug Module
```

需要两条线同时连接：一条给开发板供电，一条连接下载器。仅能充电的线不能用于 FT232H
数据通信。下载器的 VREF 是 3.3V 电平参考，不承担开发板供电。

## 1. 文件与硬件设置

| SRAM 布局 | Flash 烧写文件 | 对应 PC 参数 |
|---|---|---|
| CPU/NPU 各 8KB | `fpga/ego1/build/ego1_jtag_private_flash.mcs` | `--layout private` |
| CPU/NPU 共享两个 8KB bank | `fpga/ego1/build/ego1_jtag_shared_flash.mcs` | `--layout shared` |

两版均为 `xc7a35tcsg324-1`、系统 50MHz、4 lane、JTAG 冷加载，CPU 在 Boot ROM 等待 RUN。
镜像从 Flash 地址 0 开始，SPIx4，Flash 容量 64 Mbit / 8 MiB；FPGA 配置时钟保守设为
6MHz，与 SoC 的 50MHz 系统时钟无关。`.bin` 是等价的二进制配置镜像，`.bit` 是对应 FPGA 配置文件。

默认 Flash 型号依据 EGo1 V2.2 官方指南：Vivado 选择
`n25q64-3.3v-spi-x1_x2_x4`。实际烧写前核对你这块板的 Flash 丝印/版本；不同型号不能只按
容量相同就直接套用。脚本允许第二个参数指定已确认、Vivado 支持的 64-Mbit/3.3-V 型号。

烧写会替换地址 0 的原配置，包括出厂演示程序；本流程只保留一个当前启动镜像。
要从 private 换成 shared，需要重新烧写对应文件，不能仅修改 PC 的 `--layout`。

## 2. 先连接开发板到电脑，烧写一次 Flash

暂时不接外部 FT232H。用电脑的 USB-A 接 EGo1 板载 USB-UART/JTAG 接口并打开板卡电源。
在仓库根目录的 PowerShell 中执行以下一个命令：

```powershell
# 推荐先使用当前共享 bank 版
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_flash.tcl -tclargs shared

# 若要使用独立 SRAM 版，则改为：
# & E:\Vivado\2023.2\bin\vivado.bat -mode batch `
#   -source fpga/ego1/program_flash.tcl -tclargs private
```

脚本检查唯一配置线缆和 XC7A35T，加载 Vivado 临时 Flash 编程桥，执行擦除、空白检查、
写入及校验。看到 `FLASH_PROGRAM_VERIFY_PASS` 才表示烧写和校验成功；失败不会输出该标志。
脚本结束时 FPGA 中可能仍是临时编程桥，下一步必须重新上电，不能立即拿它跑 SoC。

也可以在 Vivado Hardware Manager 右击 FPGA → Add Configuration Memory Device，选择与
实物一致的 Flash 型号 → Program Configuration Memory Device，选择相应 `.mcs`，勾选
Erase / Program / Verify。不要仅用 Program Device 下载 `.bit` 代替 Flash 烧写。

## 3. 断电，改为充电头供电

1. 关闭开发板电源，断开开发板与电脑的 USB 连接。
2. 按板卡丝印/手册，将 **JP2 设为 QSPI 启动**；不要凭“左边/右边”判断不同板卡版本。
   本次实物标记为左 QSPI、右 JTAG，三针跳帽跨接左侧和中间两针，右侧一针露出。
3. 把开发板 USB 线的另一端接 USB 充电头，再打开板卡电源。
4. 等 FPGA 配置完成。官方手册的配置完成指示为 D24；本 SoC 的 LED0 表示 MMCM locked，
   LED1 为心跳。CPU 此时在 ROM 等待，尚未加载模型，也不会自动进行 MNIST 推理。
   LED4 显示外接 TCK 边沿活动；确认调试连接应以 OpenOCD 的 TAP/CPU/版本 ID 读取为准。
5. 用另一根数据线把 FT232H 接电脑唯一的 USB-A，按 [Lab6 接线表](lab6-jtag.md#3-烧写-fpga-与接线)
   将它连接 J5。

板卡 Flash 上电启动和 JP2 设置依据
[EGo1 官方操作指南](https://e-elements.readthedocs.io/zh/ego1_v2.2/EGo13.html)。

## 4. 用原来的 OpenOCD 和 PC 程序运行

先打开 Ubuntu WSL 终端并保持运行，再在 Windows 管理员 PowerShell 执行（首次共享下载器需要管理员权限）：

```powershell
.\fpga\ego1\attach_ft232h.ps1
```

Ubuntu WSL 的第一个终端：

```bash
cd /mnt/c/Users/zhujunan/Desktop/tapeout/mynpu
sudo bash fpga/ego1/start_openocd.sh
```

第二个 Ubuntu 终端先做短测试，再做连续推理：

```bash
cd /mnt/c/Users/zhujunan/Desktop/tapeout/mynpu
python3 tools/jtag_host.py --layout shared --boots 1 --runs 5
python3 tools/jtag_host.py --layout shared --boots 3 --runs 64
```

首次连通按 Lab6 默认 10kHz。已验证连接后，可在启动 OpenOCD 时覆盖为 100kHz：

```bash
sudo bash fpga/ego1/start_openocd.sh -c 'adapter speed 100'
```

本次前 5 次短测试使用 10kHz，随后 3×64 次回归使用 100kHz。此参数只影响 JTAG 传输，
SoC/NPU 的系统时钟始终为 50MHz。

独立 SRAM 版将 `shared` 改为 `private`。GDB 手动调试仍使用
`bash fpga/ego1/debug_cpu.sh shared`，详见 [Lab6 主指南](lab6-jtag.md)。

每次板卡断电后，Flash 中的 FPGA 配置仍保留，SRAM 中的固件/模型/输入需重新加载。
恢复供电后重新启动 OpenOCD，再运行 PC 程序。`--boots 3` 测试的是 DM 复位/重新加载，
不代表三次真实断电；Flash 上电启动需另外通过实际关电/开电验证。

## 5. 重建与验证边界

在完整源码仓库中，如果已有两套 routed checkpoint：

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_flash.tcl -tclargs all
python tools/verify_flash_images.py
python tools/package_jtag_kit.py
```

若缺 checkpoint，先运行 `build_jtag_private.tcl` / `build_jtag_shared.tcl`，再生成 Flash 镜像。
`build_flash.tcl` 不连接硬件，也不改原 `.bit`；只基于现有布局布线结果设置 FPGA 的 SPI 启动选项。
运行包已包含生成好的镜像，无需本机重新综合。

2026-10-19 已在 Vivado 2023.2 生成两套镜像。离线检查逐条验证 MCS 校验和、地址连续、
MCS/BIN/bit 配置数据一致，并比较 FAR/FDRI，确认所有 FPGA 配置帧（包括 BRAM 内容）
与原 Lab6 版本完全一致；结果与 SHA256 见 [Flash 镜像记录](lab6-jtag-flash.json)。
本次没有改 CPU/NPU/ASIC RTL，不把镜像转换算作新增 ASIC 压力测试。

2026-10-19 已将 **shared / 4-lane** 镜像实际烧入 EGo1，Vivado 识别 Flash ID 为
`20 BA 17`，擦除、空白检查、写入及读回校验均成功，输出 `FLASH_PROGRAM_VERIFY_PASS`。
实体烧写证据见 [板卡记录](ego1-flash-board.json)。private 版仍仅完成镜像生成与离线检查。
随后已完成充电头供电、QSPI 断电上电启动，外接 FT232H 读取版本 ID `0x4a541104`、
RUN=0、CPU PC=`0x00010008`。CPU 固件/模型通过原 DM SBA 下载并逐字核对，运行
5 次短测试及 3 次 DM 复位/重装、每次 64 张 MNIST 输入，共 **197 次 CPU-in-loop 实板推理**，
全部十个输出码与整数参考 bit-exact，与导出的 PyTorch INT8 输出最大差值 1，IRQ 计数全部正确。
NPU 每次 35570 周期，即 50MHz 下 0.7114ms；USB/JTAG 传输时间另计。
GDB 也实际读回了 CPU 寄存器、版本 ID、最终 DONE sequence=63 和 IRQ=64。

这是一次真实断电上电启动及四次 DM 复位/重新加载，不等于四次断电测试。
完整数据/日志在 `build/ego1-flash-jtag-validation.tgz`，运行包也包含本次板测数据与日志。
既有 VCS 的
ASIC/FPGA 四配置、768 次推理记录见 [原验证记录](lab6-jtag-verification.json)。
FPGA 板载 QSPI 只恢复 FPGA 电路，不是给 ASIC 新增 SPI 固件加载器，也不增加 SRAM。
