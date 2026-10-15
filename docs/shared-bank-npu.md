# 双 8KB 共享 bank 的 ASIC/FPGA SoC

分支：`feature/dual-bank-shared-sram`。主实现仍为完整 ASIC SoC；FPGA 使用同一控制器、计算核心和单口读写契约，仅替换存储 wrapper。

设计原则：**同拍需要的数据尽量落在不同 bank，或已经缓存于寄存器。** 两块宏各自仍然只有一个 32-bit 端口。模型只保存一份 PACK4 权重，不采用两 bank 权重复制方案。按字交错不是无冲突保证；真实冲突必须计数和仲裁。

## 连接与地址

启用 `mynpu_soc_top.DUAL_BANK_SHARED=1`，设置 `NPU_LANES=4`、`NPU_ACT_CACHE_WORDS=1`；ASIC 设置 `USE_ASIC_SRAM=1`，FPGA 设置 `USE_FPGA_BRAM=1`。历史默认配置与旧 NPU 后端保留，必须显式启用新架构。

crossbar 为 **3 个请求入口 × 3 个目标出口**。入口仍是 CPU 指令、CPU 数据、Debug Module SBA。出口为 Boot RAM、共享存储/NPU 子系统、DM 调试执行窗口。CPU 原 SRAM 地址规则和 NPU 地址规则指向同一个 AXI 目标。

| CPU/Debug 全局地址 | 含义 |
|---|---|
| `0x00010000..0x0001003f` | 64B Boot RAM，跳转至 CPU 程序 |
| `0x80000000..0x80001fff` | 物理 bank0 的连续字节视图 |
| `0x80002000..0x80003fff` | 物理 bank1 的连续字节视图 |
| `0x70000000..0x7000001f` | NPU CONTROL/STATUS/描述符/周期寄存器 |
| `0x70004000..0x70007fff` | 两 bank 的 16KB 交错逻辑视图 |
| `0x00000000..0x00000fff` | DM 调试执行窗口 |

NPU 逻辑字节偏移 `a`：`bank=a[2]`、宏 word row=`a[13:3]`、字内 byte=`a[1:0]`。例如逻辑字 0/2/4 在 bank0，1/3/5 在 bank1。CPU 物理视图与交错视图是同一存储的别名，无镜像数组。

每个 bank 独立仲裁三个请求者：AXI host、NPU 权重/参数/输出端口、NPU 激活端口。每 bank 采用 round-robin；不同 bank 可同拍各接受一个请求，同 bank 每拍只接受一个。接受请求后下一拍返回带来源归属的响应。等待中的请求保持地址、数据和写掩码，不能丢失。

新 `mynpu_axi_shared` 使用 grant/response 握手，支持 FIXED/INCR burst 和 byte strobe，R/B 响应在 backpressure 期间稳定；不支持的 WRAP/超宽访问返回 SLVERR。AR/AW 轮换优先级，避免 CPU 连续读取使 SBA 写饿死。NPU 运行中，CPU/SBA 的共享内存请求正常仲裁等待，不返回旧版 BUSY 标记。

## 容量与加载

| NPU 逻辑偏移 | 内容 |
|---|---|
| `0x1000..0x20bf` | 单份 PACK4 权重、bias、M、shift，共 4288B |
| `0x2400..0x24d7` | 6×36B 描述符 |
| `0x2800` | 激活 A，最大 784B；输入及最终 10B 输出 |
| `0x3000` | 激活 B，最大 392B |

权重、激活和描述符都按字跨两个 bank 分布。bank0 的 `0..0x7ff` 为 CPU 程序/只读常量/数据/BSS，`0x1bc0..0x1fbf` 为 1KB 栈，`0x1fc0..0x1fff` 为 mailbox。链接器强制代码与 BSS 不超过 2KB。模型/激活加载区到逻辑 `0x3400` 为止，映射到每个物理 bank 的 `0x1a00` 以下，不覆盖栈。

CPU 自测程序 1704B，流式程序 872B。CPU 固件不再嵌入并复制整份参数。ASIC 冷启动由 JTAG/DMI/SBA 在 `boot_ready_i=0` 时先写 CPU 程序，再通过交错窗口写模型/描述符/输入，之后释放 CPU。FPGA 的 `cpu_bank0.hex`/`cpu_bank1.hex` 是相同物理布局的 bitstream 初始化镜像。

CPU 配置描述符后 START，执行 WFI；本地 IRQ16 保持使能，在检查中断计数和进入 WFI 期间屏蔽全局 MIE，随后重新使能以处理已挂起 IRQ，避免丢失唤醒。错误状态也触发已使能的 IRQ，ISR 检查错误，不把错误当作推理完成。CPU 读出结果并发布 mailbox 完成标记后，主机才写下一张输入。

## NPU 调度与缓存

`cnn_npu_banked` 支持 1/2/4/8 lane，使用 PACK4 描述符（不接受旧 OC-major 权重）。TERM 同时提交权重和激活读；冲突时分别等待 grant，并保留已返回的数据。最后一个必要响应可以直接旁路送入 MAC，在响应时钟沿更新全部有效 lane，省去独立 MAC 等待状态。8 lane 的两组 PACK4 权重仍通过权重请求端口分拍预取，不能宣称每拍完成 8 MAC。

激活缓存大小为 `ACT_CACHE_WORDS` 个 32-bit word，要求为 2 的幂。默认 1 个 word。缓存跨空间位置保留；每层开始/START/复位失效，输出或 host 写仅使匹配的 word tag 失效，host 写与同拍 cache fill 也处理失效。它没有增加 SRAM 宏端口。128B 数据缓存还需 tag/valid 和选择逻辑，面积并非只有 128B。

请求时寄存激活地址；响应字节选择/MAC 使用这个寄存地址。层初始化预计算输入/输出平面大小，每个输出位置初始化预计算 `oy*stride` 与 `ox*stride`，避免坐标乘法串接到 MAC 的时序路径。这些计算利用已有 INIT/GINIT 状态，不增加推理周期。

同一固定模型、4 lane、ASIC 功能宏、无 host SRAM 流量的实测：

| 缓存数据字节 | cycles | 激活缓存命中项 | 激活 SRAM 读取 | 同 bank 冲突项 |
|---:|---:|---:|---:|---:|
| 4 | 35569 | 5817 | 5288 | 2652 |
| 16 | 35225 | 6546 | 4559 | 2308 |
| 32 | 34968 | 7086 | 4019 | 2051 |
| 64 | 34519 | 7957 | 3148 | 1602 |
| 128 | 33534 | 9899 | 1206 | 617 |

4B 缓存下的逐层冲突为 410、800、808、272、308、54；合计 2652。这里每个冲突项增加一个等待周期。**20,000 是独立仲裁压力测试持续的周期数，不是模型冲突数。** 128B 缓存减少 77.2% 的激活读取，但只减少 5.7% 的总周期；当前仍受 term 状态调度、requant 和输出处理影响，默认不盲目扩大缓存。

完整 SoC 的周期可能与无 host 的 NPU 测量相差几个周期，因为 START 后 CPU 进入 WFI 前仍有少量访问。原独立 CPU/NPU 单口版本为 65732 周期；新单份权重、4B 激活缓存的 SoC 约 35574 周期，50MHz 下约 0.7115ms，计算段约加速 1.85 倍。模型装载、CPU/JTAG 传输与结果发布另计。

实体 EGo1 自运行版本为 **35570 周期，50MHz 下 0.7114ms**。使用完全相同的物理 BRAM 初值、关闭 SBA 轮询后的完整 SoC 仿真也稳定为 35570；21 次启动/105 次推理均与板测一致。带 JTAG/SBA mailbox 轮询的测试为 35574，不能把不同 host 流量下的这 4 周期差异当作计算结果差异。

## 功能回归记录

最终主要模拟 seed 为 8675313，随机算子数据 seed 为 14596；早期缓存扫参 seed 为 424242。ASIC 与 FPGA 使用相同测试与数字行为，ASIC 接私有 RA1SHD 模型，FPGA 接同步单口 BRAM。

- 两个后端的 4-lane/4B 缓存：各 200 次连续完整模型推理，全部 358800 个逐层输出 byte 严格等于独立整数 golden，逐 byte 检查已有 PyTorch 结果差值不超过 1。测试期间并发 host SRAM 访问，并每 11 轮 warm reset。
- 两个后端：各 200 组随机 FC/卷积，包括非方形输入、stride1/2、通道尾部、非对齐激活/输出、INT8/UINT8 极值、INT32 回绕、shift0/1/31/63、ReLU/qmax。逐次比较完整 16KB SRAM，包括未写区域。
- 两个后端的完整 SoC：各三次真实 JTAG/DMI/SBA 冷加载、每次五轮 CPU 推理及五次 IRQ；CPU WFI、halt/resume、推理中复位后重新加载。每次自测周期为 35574。
- 两个后端的流式 SoC：各 64 张不同 MNIST 量化输入，CPU 发 START、WFI、ISR、读结果；SBA 推理期间执行 512 次双 bank 空闲区域写入并读回，检查全部 640 个输出码。
- 两个后端的 128B 激活缓存：各 200 组随机算子全区比较及三次启动/15 次完整 SoC 推理；SoC 自测周期为 33536。
- 默认/128B 缓存分别检查 CPU 物理地址别名写入会使对应的 NPU 逻辑 word cache tag 失效；避免两个地址视图产生旧缓存。
- FPGA 物理初始化镜像启动、无 SBA 流量的完整 SoC：21 次启动/105 次推理、每次五轮均由 CPU WFI/IRQ 完成，严格检查全部输出码；周期 35570，与实体板一致。
- 两个后端的 8-lane 对比：各 10 次完整 NPU 推理、200 组随机算子、三次启动/15 次完整 SoC 推理。SoC 周期为 30853；单独 NPU 加 host 干扰测量为 30859。当前 FPGA 工程默认仍是 4 lane。
- 仲裁器两个后端各 20000 周期三请求者随机竞争、同 bank 同地址 RAW、byte mask、复位与保留检查；约 19000 次读响应逐一检查。该测试主动制造冲突，与模型实际冲突率不同。
- AXI 桥通过 1000 组随机 burst，独立 WVALID 间隔、每响应周期随机 RREADY/BREADY、byte mask、FIXED/INCR、同时 AR/AW，以及响应保持检查。
- 原独立 SRAM 的 4-lane ASIC/FPGA SoC 回归仍通过，周期保持 65732。`third_party/lab3` 全部 206 个文件 SHA256 保持原样。

日志汇总工具 `tools/collect_banked_results.py` 只归档 compile/run 文本日志与 PASS 记录，不包含私有宏或仿真二进制。64 张流式覆盖不是把全部 10000 张 MNIST 都跑过 RTL；完整测试集准确率沿用原模型的 PyTorch/整数参考记录。

## 复现

```sh
# 可在 WSL 中使用之前下载到 tapeout/riscv-tool 的 Linux 工具链
python3 tools/build_banked_assets.py --gcc /path/to/riscv64-unknown-elf-gcc
python3 tools/build_npu_stress_vectors.py --banked --cases 200 --seed 14596
# 64 张 MNIST 向量沿用原版量化输入及独立整数输出（数值不因地址重排改变）
# 若缺失 build/mnist-regression 文件，用 eeml PyTorch 环境生成：
python tools/mnist_regression.py --layout 8k-p4 --random-vectors 64 --seed 14596

# 在有 VCS 的 Linux 主机执行；ASIC 不公开私有宏
python3 tools/run_banked_regression.py --memory asic --macro-model /private/path/RA1SHD_2048x32M8.v --suite fixed --runs 100 --seed 8675309
python3 tools/run_banked_regression.py --memory asic --macro-model /private/path/RA1SHD_2048x32M8.v --suite random --runs 200 --seed 8675309
python3 tools/run_banked_regression.py --memory asic --macro-model /private/path/RA1SHD_2048x32M8.v --suite soc --seed 8675309
python3 tools/run_banked_regression.py --memory asic --macro-model /private/path/RA1SHD_2048x32M8.v --suite stream --vectors 64 --seed 8675309
# FPGA 同样执行上述套件，--memory fpga；另外运行 --suite edges/fabric/axi。
# 缓存对比使用 --cache-words 1/4/8/16/32，--runs 1 自动关闭干扰流量。
```

EGo1 独立工程：`fpga/ego1/build_autonomous_dual_bank.tcl`，器件 `xc7a35tcsg324-1`。生成 `_dual_bank.bit/.ltx`，不覆盖原 `_4lane` 工程。新固件每次启动五次推理均使用 IRQ，故 VIO 预期为 5 次 IRQ。程序下载命令末尾使用 `-tclargs --program 20 dual_bank`。

2026-10-15 已实际下载此双 bank、4-lane、4B 激活缓存版本。一次初始启动加 20 次 VIO 软复位，**21 次启动、105 次完整推理全部通过**：每轮 mailbox=`0xc0dec0de`、error=0、class=2、IRQ=5、cycles=35570；复位期间检查 mailbox/IRQ 观察值清零。板上使用固定自测输入，每次推理由 CPU 检查全部 10 个整数输出码。64 张不同 MNIST 的覆盖仍属于上述 VCS CPU-in-loop 仿真。

最终 FPGA 已布线报告：50MHz 约束下 WNS=+1.265ns、WHS=+0.029ns，setup/hold failing endpoints 均为 0。含完整 SoC、VIO/debug hub 的资源为 11567 LUT、8745 FF、17 DSP、4 RAMB36E1。两块逻辑 8KB 存储各占两个 RAMB36E1；没有第三块 CPU SRAM。较大的可选缓存只完成了功能回归，此次实体板和时序结果对应默认 4B 缓存。

板测记录、bit/ltx 与报告 SHA256 见 [dual-bank-fpga-board.json](dual-bank-fpga-board.json)，仿真记录见 [dual-bank-verification.json](dual-bank-verification.json)。本机完整板测日志为 `build/ego1-dual-bank-board-20261015.log`。板载 USB-JTAG/VIO 负责 FPGA 配置与观测，外部 RISC-V DM 探针未参与板测；ASIC 的 JTAG/DMI/SBA 冷加载流程已由功能仿真覆盖。

```powershell
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/build_autonomous_dual_bank.tcl
& E:\Vivado\2023.2\bin\vivado.bat -mode batch `
  -source fpga/ego1/program_autonomous.tcl `
  -log build/ego1-dual-bank-board-20261015.log `
  -journal build/ego1-dual-bank-board-20261015.jou `
  -tclargs --program 20 dual_bank
# 在 VCS 主机上复现与自运行板相同的物理 BRAM 初始化路径：
# python3 tools/run_banked_regression.py --memory fpga --suite preinit --seed 8675314
```

真实宏 timing check / PDK 签核按用户要求不执行。功能仿真使用 `+notimingchecks +no_notifier`；FPGA 时序及资源只能说明 FPGA 实现，不能代替 ASIC 时序、面积或功耗结论。
