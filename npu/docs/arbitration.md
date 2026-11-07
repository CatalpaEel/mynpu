> 本页为仲裁精简后的带缓存基线；当前已[删除透明SRAM缓存](no-sram-cache.md)，最新面积见该报告。

# XBAR仲裁精简

本轮改写RF、SRAM/MMIO和流FIFO的请求选择。容量、端口数量、地址映射、错误响应、VPG2指令与固件均不变。RF仍256B、8个单端口物理bank、两个普通逻辑访问lane和9个逻辑gather槽；流FIFO仍为4×16×32bit，SRAM读缓存仍为每bank16words。

## 实现

通用选择器位于`rtl/common/npu_rr_select.sv`。先根据轮询起点生成优先掩码，再从请求位中取最低有效位：

```text
masked = requests & priority_mask(first)
candidates = masked != 0 ? masked : requests
grant = candidates & (~candidates + 1)
```

运算宽度为请求数N，不再在每个候选项中计算32位`(pointer+offset)%N`并动态索引请求和地址。调用方只在实际服务后把指针推进到获胜者之后，末尾回到0。不存在新增仲裁流水级。

RF把有效性、bank编号等在每个输入端口译码一次，随后每个bank只选择请求位。普通访问的地址行、写数据、字节使能在两个逻辑lane各选一次，再供给对应bank，避免在多个bank中重复选择宽字段。gather只选择窄行号；有效对齐地址的`(bank,row)`唯一确定一个字，因此同字广播只需比较行号和已译码bank候选掩码。返回数据和流FIFO写入/响应路径使用独热掩码OR选择，替代层叠的优先宽数据选择。

```mermaid
flowchart LR
  P[输入端口] --> D[每端口地址译码]
  D --> B[每bank请求掩码]
  B --> R[掩码轮询：选择请求位]
  R --> S[独热选择行号/写数据]
  S --> RF[单端口物理bank]
  RF --> O[按响应掩码返回]
```

普通访问与gather仍按bank交替服务；同字gather广播仍一次授权多个请求；不同字冲突继续等待。流FIFO的空队列直通、满队列反压、字节掩码及同周期读写均保留。

## 验证

13组最终回归通过，所有报告的源码哈希均已与当前文件复核：

- 选择器在N=1、3、4、6、7、9时，对所有请求位图和合法轮询起点穷举，共5,978例。
- 冻结旧RF实现作为独立参考，对3路/9路gather、4个/7个普通请求者和256B/512B/2KB容量逐周期仿真对照，共31,408个采样周期。覆盖随机读写、字节使能、冲突、同字广播、无效地址、请求排除及复位；授权、响应、数据和错误一致。
- 共享RF473项、流FIFO4,000轮、xbar并发5,069项、RF写回868项、普通xbar公平性/缓存一致性测试通过。
- JTAG42项、单元流路由24项、共享操作数3,409项通过。
- 实际SRAM宏模型下，10张MNIST逐层整数检查通过，每张仍为29,817周期，性能无变化。

[功能机器报告](../reports/arbitration_validation.json)。本轮综合采用与前版相同的TSMC180 TT、low effort、16ns优化/20ns报告；最终测量见`arbitration_area_validation.json`。尚未重新布局布线。

```bash
python3.12 npu/scripts/run_vcs.py --suite arbiter --tag MY_RR
python3.12 npu/scripts/run_vcs.py --suite rfequivalence --tag MY_RF_EQ
python3.12 npu/scripts/run_vcs.py --suite rfequivalence --rf-bank-words 256 --tag MY_RF_EQ_2KB
python3.12 npu/scripts/run_vcs.py --suite latency --macro --tag MY_RR_MNIST
```

## 综合实测

相同TSMC180 TT、low effort、16ns优化/20ns报告下：

| 部分 | 旧版/mm² | 新版/mm² | 节省 |
|---|---:|---:|---:|
| 整芯片默认优化 | 2.808663 | 2.543393 | 9.44% |
| XBAR合计（保留层级） | 0.781665 | 0.522962 | 33.10% |
| 其中：共享RF与访问逻辑 | 0.350451 | 0.204720 | 41.58% |
| 其中：流FIFO与路由 | 0.257236 | 0.169215 | 34.22% |
| 其中：SRAM缓存、普通端口仲裁等 | 0.173978 | 0.149028 | 14.34% |

整芯片总面积使用默认优化结果，XBAR与其分项使用保留计算核层级的版本；保留层级版整芯片合计2.543632mm²。均包含两块真实SRAM，不含PAD、CTS、filler、布线或放置留白。

50MHz综合setup slack为+4.0021ns，TNS为0.0000ns，违反路径0。尚未重新布局布线。

原始报告：
- [20261107-arbitration-area/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-arbitration-area/reports/area.rpt)。
- [20261107-arbitration-area-hier/area.rpt](/home/s2400012841/chip-fullstack-2026/eda-runs/20261107-arbitration-area-hier/reports/area.rpt)。

[完整面积机器报告](../reports/arbitration_area_validation.json)。源码、冻结输入及库哈希均已复核，并与13组功能回归的RTL对应。
