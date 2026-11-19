# EGo1 固定上板版本：ego1-10mhz-20261116

本目录保存实际烧写并完成测试的镜像、源码快照和配套文件。
在10MHz系统、100kHz外接JTAG下，**启动后不暂停CPU，2021次推理全部通过**。
后续主分支更新不自动获得本目录的验证结论，复现实验请使用固定标签。

## 版本对应关系

| 项目 | 固定标识 |
| --- | --- |
| 版本标签 | `ego1-board-running-10mhz-20261116` |
| 合入目标 | `main` |
| 保留的验证分支 | `fpga/ego1-sba-validation-20261115` |
| 实际硬件源码 | `53655b5aff75b21021c3aadcd66d0d57b9c2e52e` |
| PC物理地址修正 | `824c10936f69630703b66bec36434da1b9bcaabd` |
| 完成板测记录的提交 | `c5abb77647ef0b42fea4c59757b6435995d1cc55` |
| 实际硬件输入 | `hardware/source_manifest.json`，82个输入文件、72个编译源码 |
| 程序、模型、输入和golden | `assets/manifest.json` |
| 实板结果 | `board_validation.json`，原始记录在 `evidence/board/` |

本次硬件快照与53655b5对应文件逐项一致，Git比较仅统一CRLF/LF；
原始字节则完整保留，并按构建时的SHA256核对。PC修正及本目录归档没有改变该镜像的硬件源码。
`hardware/source_origin.json`保留构建时尚未板测的历史状态；最终实板状态以本目录的
`VERSION.json`和`board_validation.json`为准。

## 镜像与资源

EGo1 / `xc7a35tcsg324-1`，Vivado 2023.2，10MHz，area-medium、CPU RF LUTRAM、CNN DSP。
CPU为CV32E40P，NPU为独立CNN / Matrix / Vector；两块逻辑8KiB单口存储在FPGA映射为4个RAMB36。
共享ASIC RTL保持53655b5，ASIC仍使用原CPU RF及SRAM后端。

| 项目 | 结果 |
| --- | ---: |
| LUT / FF | 20048 / 13167 |
| RAMB36 / DSP | 4 / 56 |
| setup / hold slack | +45.764ns / +0.030ns |
| 完全布线网络 | 34024 |
| 默认DRC Error | 0 |

DRC保留283项Warning；CDC报告保留19项异步复位Critical、2项ASYNC_REG与263项使能结构Warning。
原报告完整保存在`hardware/reports/`，不将功能板测表述为CDC或ASIC物理签核。

- `ego1_mynpu.bit`：SHA256 `da0d5d534a868326fdc14be013a6d52419a6a17a0295f0c044edd7e266ad9188`。
- `ego1_mynpu.mcs`：SHA256 `3e5cc76e561c0ff8c4103da508804efec9fa43ae49397cae4a594b05c1c04dc8`。

Flash为`n25q64-3.3v-spi-x1_x2_x4`，本次已完成擦除、空白检查、写入、校验及操作者断电重启。
MCS只保存FPGA配置；每次上电后仍通过外接JTAG装载CPU程序、模型和输入。

## 实板结果与已修正问题

| 测试 | 推理数 | ndmreset后完整加载批次 |
| --- | ---: | ---: |
| 单次推理 | 1 | 1 |
| 复位后重载 | 20 | 20 |
| 连续推理 | 2000，两批各1000 | 2 |
| 合计 | **2021** | **23** |

每次比较全部十个最终整数输出、CPU分类和完成序号；连续记录无跳号、重号或槽位错误。
最后一批的完成计数为Matrix 13000、CNN 212000，与每次13及212项任务一致。
CPU维持运行态，SBCS错误位为零。输入是十张固定golden样本的顺序变化，不是完整MNIST。

首次运行态读内存曾报`Failed to read priv register`。保持CPU运行，直接DMI/SBA读回固件PASS及正确输出；
仅将OpenOCD翻译模式按sw/off/sw/off切换，同地址读取稳定地失败/成功/失败/成功。
原因是本机OpenOCD默认软件地址翻译先读取CPU特权寄存器，运行态下该读取失败，尚未进入SBA访存。

本项目使用裸机物理地址，已固定：

```tcl
riscv set_mem_access sysbus
riscv virt2phys_mode off
```

这一修正仅在PC配置和加载器初始化，无需为此修改芯片RTL或重生成当前bitstream。
失败、对照与成功结果均保留；不能把本次priv错误的定位扩展为所有可能硬件故障均已排除。

另有ASIC功能宏、50MHz与FPGA BRAM/LUTRAM、10MHz的完整SoC仿真，各200帧、2次启动、11006检查通过，
并逐周期监测运行阶段CPU未halt，见`evidence/simulation/`。ASIC宏文件不随归档发布。
板上每帧前后检查DMSTATUS，属于采样检查。主机协议往返时间不是纯NPU推理延迟。

## 复用

从仓库根目录先验证所有字节哈希：

```sh
python3 npu/fpga/ego1/verify_board_bundle.py npu/fpga/ego1/versions/ego1-10mhz-20261116
```

将整个版本目录复制到一个独立工作目录，例如`npu/build/ego1-running-kit`，保留本归档原件。
进入复制出的目录，用板载配置USB下载bit；单USB-A时可先烧写MCS：

```sh
vivado -mode batch -source npu/fpga/ego1/program_fpga.tcl -tclargs /absolute/path/ego1_mynpu.bit
# 或烧写并校验Flash
vivado -mode batch -source npu/fpga/ego1/program_flash.tcl -tclargs /absolute/path/ego1_mynpu.mcs
```

Flash写入结束后断电，确认JP2为QSPI，用充电头给板供电，USB-A接外接FT232H；
按此前Lab6连接J5：AD0=TCK、AD1=TDI、AD2=TDO、AD3=TMS及公共GND、参考电平。
重新上电后LED0常亮、LED1闪烁。WSL保持运行，再按实际USB编号附加FT232H。
板载0403:6010是配置接口，外接0403:6014是RISC-V调试接口。

本次OpenOCD为`0.12.0+dev-04406-g10b7a647d`。在WSL进入复制出的板测包根目录：

```sh
openocd -f npu/fpga/ego1/ft232h.cfg -f npu/debug/target.cfg \
  -c 'adapter speed 100' -c 'bindto 127.0.0.1' -c 'tcl_port 6666' -c init
```

另一WSL终端进入相同目录，逐项执行，使用新输出目录：

```sh
python3 npu/fpga/ego1/jtag_validation.py --assets assets --cpu-access running --mode smoke --timeout 120 --out results/new-smoke
python3 npu/fpga/ego1/jtag_validation.py --assets assets --cpu-access running --mode reload --boots 20 --timeout 120 --out results/new-reload
python3 npu/fpga/ego1/jtag_validation.py --assets assets --cpu-access running --mode continuous --runs 1000 --boots 2 --timeout 120 --out results/new-continuous
```

初始复位、加载时允许暂停CPU；启动后的running测试禁止显式halt/resume，错误即停，无自动回退。
只有`--cpu-access running`的结果用于本次运行态访问结论。

重新综合时将`hardware/`复制到归档之外，从复制目录执行`vivado -mode batch -source build.tcl`。
这会生成新产物，工具版本、路径或实现过程变化后文件哈希可能不同，须另行记录。
未归档生成工程、DCP或私有PDK；完整构建输入、报告与通过标记已保留。
