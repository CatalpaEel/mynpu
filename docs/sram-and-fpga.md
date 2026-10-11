# RA1SHD_2048x32M8 与 EGo1 上板路径

`RA1SHD_2048x32M8.zip` 是 0.18µm 流片用的 SRAM macro 视图包，不是 Xilinx FPGA IP。它的 Verilog 单元是 `RA1SHD_2048x32M8`：2048 个 32-bit word，即 8192 bytes（8 KiB），11-bit word address，32-bit data，4 个 active-low byte write enable。`CEN=0` 选中，`WEN[3:0]=0` 的 byte 在时钟沿写入，四个 `WEN` 都为 1 时读；`OEN=0` 才打开 Q 输出。它没有 reset/clear 引脚，内存内容不能靠复位清空。模型是同步单端口，读写发生在 `CLK` 上升沿。

压缩包中的文件用途不同：`.v` 是 RTL/gate-level 仿真模型，`.lib` 是综合和 STA 的 timing/power view，`.lef` 是布局布线 abstract，`.cdl` 是 LVS/网表相关视图，`.vclef` 是物理实现辅助视图。`.lib/.lef/.cdl` 不应该加入 Vivado 工程。宏文件带有 ARM Physical IP 的 confidential/proprietary 声明，不应复制到公开 GitHub；流片目录通过受控 PDK 路径引用它们。

## FPGA 替身

EGo1 使用 XC7A35T-1CSG324C，板载 100 MHz 时钟在 P17，复位输入在 P15；USB 接口同时提供配置 JTAG 和 UART。[EGo1 手册](https://e-elements.readthedocs.io/zh/ego1_v2.2/EGo1.html) 还列出板载 IS61WV12816BLL，它是异步 16-bit 外部 SRAM，与这个同步 32-bit ASIC macro 不是同一种接口。因此第一版内部 SoC 验证使用 Artix-7 片上 BRAM，不使用板载异步 SRAM。

`rtl/mynpu_sram_2048x32_fpga.sv` 是一个同接口的 2048×32 同步 BRAM 推断模型。它保持单端口、逐字节写和无 memory reset；`rtl/mynpu_sram.sv` 通过 `FPGA_BRAM=1` 选择它。NPU 也有 `cnn_npu_sp_top.sv`，通过同一个单端口 SRAM backend 执行 descriptor、activation、weight、requant 和 byte-write。EGo1 shell `fpga/ego1/ego1_soc_top.sv` 使用 CPU 8KB、NPU 8KB、`LANES=1` 和 `generated/8k/cpu.hex` 预加载 CPU。

同步 RAM 的主机读路径也按一拍 SRAM 延迟处理：NPU 的 pending read 在 SRAM 输出有效的周期直接送给 AXI response，避免把 FPGA BRAM 的第二拍数据错当成旧数据。这个路径由 `sim/tb_mynpu_soc_fpga.sv` 覆盖；它让 CPU BRAM 与 NPU 单口 BRAM 连续执行固件的 5 次推理。

CPU 8KB 宏的 FPGA 映射约需要两块 36-Kbit BRAM；CPU 和 NPU 两块 8KB 存储至少要预留约四块，最终以 `report_utilization` 为准。BRAM 后端不能使用异步 reset，否则可能破坏 RAM inference；reset 只复位控制器/输出 valid，不能清除 memory 内容。FPGA smoke test 的 CPU 镜像通过 `$readmemh` 初始化，ASIC 上电后则必须由 Boot ROM、Debug/SBA 或其他启动接口加载程序。

## Vivado 第一轮

直接运行 `fpga/ego1/create_project.tcl` 会创建 `xc7a35tcsg324-1` 工程，加入 `sim/soc.f` 中的 RTL、EGo1 顶层、XDC 和 CPU hex；`build_bitstream.tcl` 会综合、实现并把 bitstream 放到 `fpga/ego1/build/`。顶层使用 P17 的 100 MHz 输入，经 MMCM 生成 50 MHz，等待 `locked` 后同步释放复位。LED0 是 locked，LED1 是 heartbeat，LED2 是 NPU IRQ，LED3 是 CPU debug-halted，LED4 是 TCK activity。J5 的 E15/E16/D15/C15 接 RISC-V `tck_i/td_i/td_o/tms_i`；板载配置 JTAG 仍只负责下载 bitstream。

第一版上板验收顺序如下：

1. 只保留 clock/reset/heartbeat，确认 P17/P15 和 LED 约束正确。
2. 加入 CPU BRAM 和 Boot RAM，`boot_ready_i=1`，确认 LED heartbeat 持续运行。
3. 加入 NPU，观察 IRQ 和状态寄存器；用 ILA 观察 `npu_req/npu_we/npu_addr/npu_wdata/npu_rdata`。
4. 增加 UART 或 VIO 读 mailbox，确认固件输出 `0xc0dec0de` 和 argmax=2。
5. 最后再把单端口 NPU 接入真实 SoC 运行，重新做逐层 golden 对照和周期统计；独立 `sim/tb_cnn_npu_sp.sv` 已完成 FPGA BRAM backend 的整数结果检查。

## 面向流片的下一步

不能把当前 NPU 的 `logic [7:0] mem[...]` 直接替换成一个 macro 实例。当前 MAC 同一拍可能读取多个 activation、多个 lane weight、bias 和 multiplier；`RA1SHD` 每拍只有一个 32-bit 地址。因此需要先定义 `req/we/be/addr/wdata/rdata/rvalid` 的 SRAM backend，再把 NPU FSM 改成：descriptor 分拍读取 → bias/scale 缓存 → activation/weight 分拍读取 → MAC → requant → 四个 byte 打包写回。

推荐先实现 `LANES=1` 的单端口版本，使 FPGA BRAM 和 ASIC macro 的周期/读延迟完全相同，再增加权重预取或 bank/cache 扩展到 `LANES=4/8`。如果仍只允许 CPU 8KB + NPU 8KB 两块宏，不能假设 8 lane 每拍都能从一块单端口宏得到 8 个独立权重；要么增加周期，要么改变存储分 bank/加入小型权重缓存。

ASIC 综合时使用 `.lib`（TT/SS/FF corners）和 macro black-box wrapper；P&R 使用 `.lef/.vclef`，LVS 使用 `.cdl`，门级仿真使用 `.v` 和相应 SDF。宏的 VDD/VSS 是物理 PG pin，RTL 仿真模型不会显示这些 pin。综合、宏放置、CTS、STA、IR/EM、LVS/DRC 都必须在换成真实 macro 后重新进行。

公开工程中的 `rtl/mynpu_sram_2048x32_asic.sv` 只包含 wrapper。ASIC flow 需要额外加入课程提供的 `RA1SHD_2048x32M8.v`，并把顶层参数 `USE_ASIC_SRAM=1`；默认 VCS/FPGA flow 保持 `USE_ASIC_SRAM=0`。综合时还要将对应 corner `.lib` 加入 link library，不能只编译 Verilog model。

宏 RTL 仿真可以用 `sim/tb_mynpu_soc_asic.sv` 做 smoke test：把压缩包中的 `.v` 放在受控 PDK/build 目录，额外加入 `rtl/mynpu_sram_2048x32_asic.sv` 和该宏文件编译。宏模型有 timing checks，零延迟 RTL 回归应按 PDK 时钟约束决定是否使用仿真器的 timing-check 选项；不能把该选项当成 STA 或流片 signoff。
