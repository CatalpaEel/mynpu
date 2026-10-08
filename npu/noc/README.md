# 可配置 NoC 试验：全部节点使用相同硬件

每个节点都是同一个 `npu_noc_core`：RV CPU、唯一 8KB SRAM 接口、CNN/矩阵/向量、NMC、原三通道 DMA、网络 DMA 端点及五端口路由器。坐标、链路使能、DDR 接入标志是启动配置输入，没有 DDR 专用节点。任何节点都可接相同的外部 DDR 服务接口；未接 DDR 的节点会对该地址范围返回错误。

```text
相同节点 (0,0) ── 相同节点 (1,0)
       │                    │
相同节点 (0,1) ── 相同节点 (1,1)
                            │
                      外部 DDR 控制器/PHY
```

ASIC 顶层 `rtl/npu_noc_core.sv` 通过原生 SRAM 端口连接宏，不包含 SRAM 模型；`npu_noc_soc.sv` 是 FPGA 测试 wrapper，只有一片原 2048×32 SRAM 模型。旧 `npu_soc` 默认关闭 NoC，仍可运行原 Tiny MNIST、矩阵、向量和 DMA 程序。

## 配置与接口

所有节点使用相同参数。`ROUTER_DEPTH` 默认 2、`MAX_WORDS` 默认 16；另验证全网统一深度 1 / 每包 4 字。坐标 `node_x_i,node_y_i` 各 4bit，mesh 宽/高输入应为 1..16。`port_enable_i[4:0]` 对应北、南、西、东、本地；本地须启用。边界方向由配置关闭。`ddr_present_i` 表示该节点的 DDR 服务可用。

这些输入是板级 strap/启动配置，在解除复位前稳定，通信期间不改变。改变拓扑必须先停止全网流量、排空并复位 fabric；仿真中 DDR 接入标志只在全网无未完成传输时改变。FPGA 时序对这些静态配置输入设 false path，所有 flit、host、DMA 和 DDR 数据握手仍按 50MHz、IO 延迟 2ns 约束。

每条方向链路暴露两个独立逻辑虚拟网络，均为 `valid/ready/data[31:0]/last`：VN0 传请求，VN1 传响应。每个入口、每个 VN 使用深度可配置的触发器 FIFO，默认数据位数为 `5×2×2×33=660bit`，无额外 SRAM。XY 路由先走 X 再走 Y；输出按完整包锁定输入，包间轮询仲裁。即使输出尚未接受首个 flit，也会保留其 owner，保证背压期间数据稳定。

**这是同一时钟域的可靠逻辑链路接口，不是已经完成的片间 PHY。** 跨芯片需要串并转换/SerDes 或 GPIO 适配、跨时钟域处理、链路初始化，以及按可靠性要求加入 CRC/重传。物理适配器须保留两个 VN 的独立流控，避免把受阻请求和响应塞入同一个不可绕过的队列。当前没有 pin 约束、实际板间链路、DDR 控制器或 PHY IP，也没有生成板级可下载 bitstream。

## 网络 DMA 与完成语义

CPU 或原 host 端口通过 `0x40000700` 的 MMIO 控制网络 DMA；CPU IRQ21 表示该节点发起的命令 done/error。真实 RV32I 演示程序启用 `mie[21]`，清除全局 MIE 后执行 WFI，再检查状态，不进入 trap。

| 偏移 | 内容 |
|---|---|
| `00` | CONTROL：bit0=start，bit1=clear；忙时写控制/描述符报错 |
| `04` | STATUS：bit0=busy、bit1=done、bit2=error、bit3=quarantined |
| `08` | 命令：`op<<8 \| destination_y<<4 \| destination_x`；1=远端写，2=远端读 |
| `0c` | 远端字对齐地址 |
| `10` | 字节数，1..8192，须放入本地 SRAM 范围 |
| `14` | 本地字对齐 SRAM 地址：远端写时为源，远端读时为目的 |
| `18` | 无进展 watchdog 周期，默认 4096，0=关闭 |
| `1c` | 已确认/本地已提交字节数，错误时也可读 |
| `20` | 错误码 |
| `24` | 本节点 `Y<<4 \| X` |
| `28` | bit5=DDR 可用；bits4:0=端口使能 |
| `2c` | 每包最多多少个 32bit 数据字 |

本地命令最多一个未完成包。长搬运分为最多 `MAX_WORDS` 个字的短包，每包完成确认后才发下一包；尾部字节使能支持 1、2、3 字节。源 SRAM 内容在完成前应由发送者保持稳定，目标缓冲必须由接收软件事先分配并保证不与 CPU/CNN 或其他写者冲突。本版本没有自动申请接收缓冲，也没有跨节点一致性缓存。

写完成表示远端原生总线已返回所有写响应，并收到对应 transaction ID 的 ACK，只有交给路由器不算完成。远端读的数据由网络 DMA 写入本地 SRAM，再验证尾部状态。服务端与本地命令独立运行，允许两端互相发起读请求；请求和响应使用独立队列。

网络 DMA 本版使用 NMC 原生握手，不挪用原 RX/TX DMA 通道。端点的本地读写与远端请求服务按事务轮询，NI 和调试 host 再轮询共享 NMC 原 host master 3；一个原生事务只在获准后等待自己的响应。原 RX/TX DMA 接口仍可接板级流式适配器，原 CPU、计算单元、SRAM 和三通道 DMA 保留。

## 地址窗口与 DDR

| 远端地址 | 服务 |
|---|---|
| `80000000..80001fff` | 该节点唯一 8KB SRAM |
| `40000000..40000fff` | 该节点 MMIO，仅完整的单字读写；支持远端装载后释放 CPU |
| `90000000..9000ffff` | 该节点 DDR 服务窗口，须 `ddr_present_i=1` |

64KB DDR 窗口是此次试验的边界，外部 DDR 模型放在 testbench，**没有在芯片内部增加 DDR 存储或 RAM**。端点暴露字对齐的 32bit 原生请求/响应接口、写字节使能和错误返回，最多一个未完成原生事务；响应必须在 grant 后至少一周期返回。接真实 DDR 需要控制器/PHY 以及这个接口到控制器总线的适配器，并保证响应/错误能够返回。当前资源数字不包含这些 IP。

## 错误与恢复

1=本地描述符/目的坐标/首跳不可达，3=远端地址范围或 DDR 未接入，4=包格式/长度/响应计数错误，7=原生总线错误，8=无进展超时。

错误不保证原子性。写入可能部分完成；ACK 错误尾记录已提交字节数。远端读也可能已写入本地部分数据。超时返回的是已确认字节数，远端实际提交量可能更大，不能据此自动重发副作用操作。

超时或本地取数总线故障使该端点 quarantine，禁止 clear/start/描述符写，防止迟到响应和 transaction ID 复用影响下一命令。迟到响应继续丢弃，不写 SRAM、不改变完成状态。恢复需要外部停止流量并复位 fabric；本版没有自动断链重路由或分布式恢复。中途断链/截断包可能保留路由器 owner；永久阻塞也可能导致同 VN 的队头阻塞，因此不能用此次测试声称所有故障下都无死锁。

## 验证与重现

```bash
cd /home/zzh/vivado/projects/xc7a35t/npu
./scripts/simulate_noc.sh
./scripts/build_noc.sh
./scripts/simulate_noc_netlist.sh
python3 noc/validate.py
```

另一个全网统一配置：

```bash
cd mnist/artifacts
verilator --binary --timing --top-module tb_noc_mesh \
  -GROUTER_DEPTH=1 -GPACKET_WORDS=4 -Wno-fatal -j 4 -I. \
  -f ../../build/sources.f ../../tb/tb_noc_mesh.sv --Mdir ../../build/obj_noc_small
../../build/obj_noc_small/Vtb_noc_mesh | tee ../../build/noc/small_mesh.log
```

Vivado 项目入口 `noc/vivado/noc_node.xpr`，设计顶层 `npu_noc_soc`、默认仿真顶层 `tb_noc_mesh`。项目重建脚本为 `scripts/create_noc_project.tcl`。原项目和原 Tiny MNIST 仿真入口保留。

测试使用四个相同实例，仅坐标、边界端口和 DDR 接入配置不同。覆盖分包/部分字节、自路由、忙时保护、四个方向的交叉写入、循环读、随机链路背压及每周期检查受阻 flit 稳定性。在节点 1 和 3 分别接入 DDR 模型，验证延迟、地址错误、缺失 DDR、总线错误和部分提交。

还验证真实 CPU 的 MMIO/WFI/IRQ21，响应阻塞超时隔离、迟到 ACK/读响应丢弃，以及经 NoC 搬入完整 8KB SRAM 镜像、远端启动原 Tiny MNIST 程序、回读十个 logits 与类别 7。所有输入通过原生总线装载，未直接预置芯片内部 SRAM。逻辑链路、DDR 服务和 host 的观测信号只用于模拟外部环境。

综合网表仿真复用同一四节点 testbench。Vivado 导出多维 packed-array 端口时展开为 escaped 标识符，`gate_adapter.py` 只添加逐端口连线 wrapper 并重命名顶层；原网表门逻辑不变，验证脚本逐字核对。网表仿真开启 `xelab -debug typical`。

结果以 `reports/noc/validation.json` 为准；ASIC 约 4mm² 的面积仍需目标 PDK、SRAM 宏与物理实现证明。

## 当前实现结果

Vivado 2025.2、`xc7a35tcsg324-1`、50MHz：整节点 17044 LUT、8858 FF、22 DSP；唯一 8KB SRAM 映射为两个 RAMB36，无 RAMB18 或 LUT RAM。相对当前关闭 NoC 的设计增加 3353 LUT、1374 FF。布局布线 WNS +0.414ns、WHS +0.098ns；启动配置引脚按上述稳定 strap 条件约束。这些资源不含实际片间 PHY 或 DDR 控制器。

默认配置和小队列配置均覆盖 481 项检查、23 个确认完成的命令。新增验证在 CNN 正在运行时，经 NoC 搬运 128 字节至不重叠的 SRAM 缓冲，并确认 Tiny MNIST 的十个 logits 和分类保持正确。默认配置另有四节点综合网表仿真，结果由验证脚本核对。
