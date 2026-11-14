# EGo1 验证分支与操作说明

分支：`fpga/ego1-asic-validation`，基线：`afb74fd`。
最终目标是 0.18µm ASIC。FPGA 验证使用同一 CPU、NPU、任务队列、RF、量化和调试 RTL，
以 BRAM 推断模型替代 ASIC 的两块单口 SRAM，并沿用现有 FPGA 时钟门控旁路与 MMCM。
默认容量和队列保持主分支配置，FPGA 功能结果不证明 ASIC 时钟树或电气特性。

## 当前上板阻塞

2026-11-13，本机 Vivado 2023.2 的默认构建已经完成综合，但实现阶段拒绝布局：
优化后需要 25,077 个 Slice LUT，XC7A35T 只有 20,800 个。
两块 8KiB SRAM 正确映射为 4 个 RAMB36，综合使用 34 个 DSP。
这是完整 SoC 的逻辑容量问题，不能关闭资源 DRC、降低频率或换一个器件名当作解决。
本版尚无可下载的 `.bit/.mcs`，不要使用之前架构的镜像代替。

`build.py --area` 只尝试 Vivado 面积映射策略，不改变芯片 RTL。
若依然放不下，需要评审等价 RTL 优化或更大 FPGA；不能为了上板静默删减 ASIC 功能。
最新实测状态与证据见 `npu/reports/ego1_validation_preparation.json`。

用户同意适当降低原型频率后，构建默认改为25MHz，支持 `--clock-mhz 10/25/50`。
这实际调整 FPGA wrapper 的 MMCM 分频，不是把时序约束写松但继续跑50MHz。
默认50MHz综合的预布线WNS为-9.351ns，也未满足时序；降低频率仍不能解决LUT超容量。
两轮未完成的50MHz面积优化已停止，不当作通过或最终资源测量。

## 变更范围

- 芯片共用源码 `npu/rtl/`、`external/`、`npu/build_config.json` 不修改。
- 新增主机校验程序、隔离的固件资产生成器、JTAG 压力测试台、操作文档。
- 原单次加载脚本改为 DM `ndmreset` 复位整个非调试系统，清旧结果，强制 32-bit SBA。
- 连续固件复用现有生成器的 QT01 路径，使用双输入槽和序号握手。它属于测试软件。
- 单次固件 `boot.bin` 和 `params.bin` 必须与主分支逐字节一致，否则生成器拒绝继续。

## 1. 准备隔离资产

从仓库根目录，使用 Python 3.9 以上：

```powershell
python npu/fpga/ego1/prepare_validation.py --out npu/build/board-assets
python npu/fpga/ego1/test_validation.py
```

输出包括单次镜像、当前 QT01 连续镜像、10 张输入和每张十个输出的整数 golden。
不重做浮点量化，不重新运行 PyTorch，不修改 `mnist/artifacts/`。
manifest 记录所有资产和芯片 RTL 哈希。主机先校验资产，再连接硬件。

## 2. 完整 FPGA 构建

```powershell
python npu/fpga/ego1/build.py --area-medium --threads 8 --clock-mhz 25 --out npu/build/board-build --vivado E:/Vivado/2023.2/bin/vivado.bat
```

`--threads 8` 可把线程上限提高到8，默认4；它不保证每个阶段都能并行。
`--area-medium` 是相对省时的中等面积策略，与 `--area` 二选一。每轮结果必须分别记录。

每次使用新的输出目录。只有实现成功并通过脚本的时序和 DRC 检查后，才会产生
`implementation_pass.txt`、`ego1_mynpu.bit`、`ego1_mynpu.mcs`。
还须审阅 BRAM 推断、内部时钟约束、CDC、布线状态和方法学报告。

构建真正通过后，可打包带哈希核对的板测包。构建/资产不匹配或缺少实现成功标记时会拒绝打包：

```powershell
python npu/fpga/ego1/package_validation.py --build npu/build/board-build --assets npu/build/board-assets --out npu/build/board-kit
```

## 3. 下载硬件配置

下面命令是明确的实体板下载操作，只能在上述构建通过后执行：

```powershell
vivado -mode batch -source npu/fpga/ego1/program_fpga.tcl -tclargs C:/absolute/path/ego1_mynpu.bit
```

板载 USB-JTAG 负责 FPGA 配置，外接 FT232H 负责 RISC-V 调试，两者是两条链路。
若电脑仅一个 USB-A，可在 Vivado Hardware Manager 中烧写当前 `.mcs` 到 N25Q64，
确认编程/校验通过后断电，JP2 选 QSPI，用充电头给板供电，再把 USB-A 留给 FT232H。
`.mcs` 仅包含硬件配置，上电后仍通过 JTAG 下载程序和输入。

J5：AD0=TCK(E15)、AD1=TDI(E16)、AD2=TDO(D15)、AD3=TMS(C15)，接公共 GND。
保持此前 Lab6 已核对的电平/参考接线。LED0 为时钟锁定，LED1 为心跳。
不要按 LED5/6 直接判断新一轮完成，必须核对本轮序号与输出。

## 4. 启动已有 WSL OpenOCD

本机 Ubuntu 中已检测到 `/usr/local/bin/openocd`，支持 RISC-V/FT232H。
先使用已有 usbipd 流程把外接 FT232H 附加到 WSL；USB 设备编号每次以 `usbipd list` 为准。
绑定如需管理员权限，由操作者在管理员终端执行，不能把 FPGA 配置 USB 误作 FT232H。

在 WSL 中进入仓库目录，保持这个终端运行：

```bash
bash npu/fpga/ego1/start_openocd.sh
```

初始 TCK 为 10kHz，RPC 仅监听本机 6666。主机程序可在同一 WSL 终端环境的新窗口执行，
不依赖 Windows 到 WSL 的端口转发。GDB 可连接 3333，基础验证不要求使用 GDB。
没有自动下载或自动恢复；启动服务后按下一节选择测试。

## 5. 依次执行板测

从仓库根目录执行，各次输出目录必须不同：

```bash
# 冒烟：整系统复位、16KiB 下载并逐块读回、真 CPU 推理、十个输出与 argmax 比较
python3 npu/fpga/ego1/jtag_validation.py --assets npu/build/board-assets --mode smoke --out npu/build/board-smoke

# 重载：20 次 ndmreset + 完整重载，循环使用十张输入
python3 npu/fpga/ego1/jtag_validation.py --assets npu/build/board-assets --mode reload --boots 20 --out npu/build/board-reload

# 连续：每批 1000 次推理不复位，双输入槽轮换，固定种子随机选择十张已知输入
python3 npu/fpga/ego1/jtag_validation.py --assets npu/build/board-assets --mode continuous --runs 1000 --boots 2 --out npu/build/board-continuous
```

“随机”指这十张有 golden 的样本的顺序，不宣称全 MNIST 或任意随机输入已覆盖。
每帧先写输入并读回，再发布 READY 序号；CPU 完成全部写回后发布 DONE。
主机检查序号、十个整数输出、CPU argmax，记录 JSONL。出现下载、版本、数值、序号或超时错误即停止，
`result.json` 保持失败。不得把上次成功标志当作本次完成，不自动重试掩盖故障。
JTAG 下载/读回时间通常远大于芯片计算时间，`host_roundtrip_s` 不是纯推理延迟。

发生故障保留日志，再执行整系统复位和完整重载。CPU halt 不会暂停 NPU，不能在活跃任务上修改参数或代码。
本脚本不自动恢复 USB 拔插、掉电、卡在空 FIFO 的 SBA 等极端故障。

## 同一压力用例的 ASIC/FPGA 仿真

在有 VCS 的主机，使用服务器支持的 Python（clab 为 `python3.11`）：

```bash
python3.11 npu/fpga/ego1/prepare_validation.py --out npu/build/sim-assets
python3.11 npu/fpga/ego1/simulate_validation.py --memory fpga --clock-mhz 25 --assets npu/build/sim-assets --frames 100 --boots 2 --out npu/build/stress-fpga
python3.11 npu/fpga/ego1/simulate_validation.py --memory asic --macro-model /private/path/RA1SHD_2048x32M8.v --assets npu/build/sim-assets --frames 100 --boots 2 --out npu/build/stress-asic
```

两后端使用相同 CPU、计算单元、固件和 JTAG 测试台，覆盖整片上传与完整读回、跨 bank、
不复位连续推理、两输入槽、IRQ/WFI、计算期间 halt/resume、POR/DM 复位后的重载、完成计数。
仿真 JTAG 为加速测试的快速时钟，不作为实板 JTAG 时序结论。
ASIC 只运行私有 SRAM 宏的功能模型，关闭 timing check，不执行 PDK 签核，不发布宏文件。
已有旧 DMA `stream` 测试已退役，不能用它证明新版连续推理。

25MHz复测曾暴露测试台末帧轮询竞态：首次读DONE仍为旧值，而第二次读RESULT时整批已成功。
修复为在最后一帧遇到成功状态时复读DONE，然后仍严格核对全部logits、argmax和完成计数。
这是等待逻辑修复，没有修改芯片。原失败日志和修复后复测分别保留，不能删除失败记录假称首次通过。

## 当前仍未覆盖

尚未完成实体掉电重启、USB 断开重连、每个计算阶段的随机复位、完整 MNIST 数据集、
任意随机算子组合和穷举仲裁验证。通过本套件也不能推导 ASIC 电气/物理签核通过。
