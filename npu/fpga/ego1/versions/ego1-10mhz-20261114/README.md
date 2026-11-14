# EGo1 实板固定版本：ego1-10mhz-20261114

这是 2026-11-14 实际完成上板验证的版本归档。后续开发请使用新分支或新版本目录，
保留本目录作为这次实验的证据。**主分支更新不代表这里的镜像、源码或板测结论同步更新。**

## 源码对应关系

| 项目 | 固定标识 |
| --- | --- |
| 发布分支 | `fpga/ego1-board-20261114-afb74fd` |
| 固定版本标签 | `ego1-board-10mhz-20261114` |
| SoC / ASIC 共用源码基线 | `afb74fd005ec76ae3afc761fa40a48a5d30aa656` |
| 本次硬件源码对应的 Git 提交 | `03e28704f6200269ef58e75b5133a30abcb01c24` |
| 实际构建输入 | `hardware/source_manifest.json` 及其列出的 82 个文件 |
| 实际编译清单 | 同一 manifest 的 `compiled_sources`，共 72 个文件 |
| 原始验证资产 | `assets/manifest.json`；程序、权重、输入、golden 均按 SHA256 固定 |
| 发布时观测到的后续 main | `1fb32ed5710c8c73bb4623fdeddf4bf00cac1d29`，未合入本分支，未由本次结果验证 |

归档时已逐文件核对：实际编译源码、CPU 头文件、其余保留的源码和构建脚本与 `03e2870`
对应文件内容一致；Git 比对仅统一 CRLF/LF。实际构建所用的原始字节保持在 `hardware/`，
按原始 SHA256 核对，不进行换行转换。`sources.tcl` 是该次参数生成文件，也按 SHA256 固定。
`03e2870` 是内容对应的提交，并非宣称构建时工作树已有这一提交。

本分支的后续提交收录 PC 侧暂停/恢复访问流程、实测记录和版本归档，不改变本次 FPGA 硬件镜像。
如修改硬件、固件、模型、输入或 PC 测试逻辑，须创建新版本并重新记录验证结果。

## 硬件与镜像

| 项目 | 本版本 |
| --- | --- |
| 开发板 / 器件 | EGo1 / `xc7a35tcsg324-1` |
| 工具 | Vivado 2023.2 |
| 系统时钟 / 已通过的外接 JTAG 时钟 | 10 MHz / 100 kHz |
| 计算单元 | CV32E40P + 独立 CNN DOT9 / Matrix 4×4 / Vector |
| 存储 | 两个逻辑 8 KiB 单口 SRAM bank，FPGA 映射为 4 个 RAMB36 |
| FPGA 专用映射 | CPU RF 使用 LUTRAM LVT 实现；CNN 使用 DSP 映射约束 |
| ASIC 关系 | 共用 SoC/NPU RTL 保持基线；ASIC 仍使用原 CPU RF 和 SRAM 后端 |
| 实现资源 | 19,799 LUT / 14,185 FF / 4 RAMB36 / 56 DSP |
| 布线后时序 | setup +48.244 ns，hold +0.019 ns，仅针对本次 10 MHz 实现 |

`ego1_mynpu.bit`：SHA256 `9bd3b176981fc5c153d47acc02f1509c66dcc5fa9132b0a6e14ba6ac5a37082a`。

`ego1_mynpu.mcs`：SHA256 `86886fa4c2c64d355b3e6157800fd831d9d7b8027f01af4a36ba41f7a97491fd`。

QSPI 器件为 `n25q64-3.3v-spi-x1_x2_x4`。本次已经完成擦除、空白检查、烧写和校验，
操作者确认重新上电后进行下述测试。MCS 只包含 FPGA 配置，程序和模型仍由外接 JTAG 装入 SRAM。

`evidence/program_flash_used.tcl` 是本次实际操作脚本的原件，保留当时的本机绝对路径作证据；
换机器时需调整其中的 MCS 路径后再使用。FPGA 配置链路与外接 J5 RISC-V JTAG 链路各自独立。

## 实际板测结果与限制

| 测试 | 通过次数 | 复位后加载批次 |
| --- | ---: | ---: |
| 冒烟 | 1 | 1 |
| ndmreset 后完整重载 | 20 | 20 |
| 不复位连续推理 | 2,000（两批各 1,000） | 2 |
| 合计 | **2,021** | **23** |

每批先完整上传 16 KiB 并读回核对；真实 CPU 调度 NPU 推理。每次比较十个最终整数输出和
CPU argmax；连续测试还检查输出包、mailbox argmax、READY/DONE 序号和双输入槽交替。
两批连续记录均无序号缺失或重复。每批末尾均检查固件 PASS。
输入是十张固定样本的随机顺序，种子为 20261113，不是 2,000 张不同输入，也不是完整 MNIST。

**已通过的是 PC 内存访问前暂停 CPU、访问后恢复的流程。CPU halt 不会暂停 NPU。**
CPU 运行中直接使用 OpenOCD `read_memory/write_memory` 曾出现读写失败，根因仍未确定。
仅关闭 OpenOCD 后台轮询未解决该问题；不能将共享 SRAM 或单 outstanding 直接认定为根因。
未宣称运行中直接 SBA 访问、USB 断开恢复、随机阶段复位、反复物理掉电或 ASIC 物理签核已通过。
`host_roundtrip_s` 包含 JTAG 传输和暂停/恢复时间，不能用作纯 NPU 推理延迟。

成功记录和失败尝试均保存在 `results/`；汇总及哈希见 `board_validation.json`。
实际执行的 Python 原件保存在 `results/validated_jtag_validation.py`。
当前配套脚本只修正了该原件的注释和 docstring，去除了未经证实的根因判断，执行逻辑未变。

## 在另一台电脑复用

只需复现本次上板时，可直接使用本归档，无需重新综合，也无需下载 ASIC 私有 SRAM 宏。
从仓库根目录先核对内容：

```sh
python3 npu/fpga/ego1/verify_board_bundle.py npu/fpga/ego1/versions/ego1-10mhz-20261114
```

用 Vivado 的板载配置 JTAG 下载本目录 `ego1_mynpu.bit`，或将对应 MCS 烧到 QSPI。
如使用 Flash 启动，JP2 选择 QSPI；给板供电，将外接 FT232H 按此前 Lab6 接至 J5。
USB 转发使用 WSL 的既有 usbipd 流程，设备编号以实际枚举为准。

在 WSL 中进入本目录，使用带 RISC-V/FTDI 支持的 OpenOCD：

```sh
cd npu/fpga/ego1/versions/ego1-10mhz-20261114
openocd -f npu/fpga/ego1/ft232h.cfg -f npu/debug/target.cfg \
  -c 'adapter speed 100' -c 'bindto 127.0.0.1' \
  -c 'tcl_port 6666' -c 'telnet_port 4444' -c init
```

本次 OpenOCD 版本为 `0.12.0+dev-04406-g10b7a647d`。
保持服务运行，在另一个 WSL 终端进入同一版本目录并依次运行。输出目录必须新建，保留本次原始记录：

```sh
python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode smoke --timeout 120 --out results/my-smoke
python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode reload --boots 20 --timeout 120 --out results/my-reload
python3 npu/fpga/ego1/jtag_validation.py --assets assets --mode continuous --runs 1000 --boots 2 --timeout 120 --out results/my-continuous
```

## 按冻结源码重新构建

重新构建会产生新输出；Vivado 版本、路径和实现过程可能使 bitstream 文件哈希不同。
**请先把 `hardware/` 整体复制到版本目录之外的新工作目录**，避免覆盖原件，再从复制出的目录执行：

```sh
vivado -mode batch -source build.tcl
```

原构建中断后曾从已有综合工程恢复实现，实际恢复脚本为 `hardware/resume_implementation.tcl`。
该脚本依赖原综合工程，不是干净检出的起始入口；干净重建使用 `build.tcl`。
前置资源估算检查仅延后到布局后，布局后与最终输出均恢复默认资源 DRC。
未归档生成工程、DCP、私有 PDK 或 SRAM 宏；完整构建输入、最终报告和成功标记已保存。

所有冻结文件由 `MANIFEST.sha256` 记录字节哈希。`.gitattributes` 禁止本版本目录自动换行转换，
便于 Windows 与 WSL 检出后核对同一份证据。归档保持原件格式，不对其进行空白格式化；
bit/bin/MCS 作为二进制产物处理。
