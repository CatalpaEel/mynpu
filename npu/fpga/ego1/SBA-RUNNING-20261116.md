# 实板运行态 SBA：OpenOCD 地址翻译问题定位

硬件为 `53655b5aff75b21021c3aadcd66d0d57b9c2e52e`，10MHz，
新镜像已烧写、校验并经操作者断电重启。外接 FT232H / J5，JTAG 100kHz。
本次定位和修正未修改芯片 RTL、固件、模型或 FPGA 镜像。

## 首次失败

原 PC 脚本在装载 16KiB 镜像、设置 RUN、恢复 CPU 后，第一次
`read_memory 0x40000004 32 1` 报 `Failed to read priv register`，继而读内存失败。
失败记录保留，未计为通过，也没有自动切回 halt/resume。

## 对照证据

CPU 保持运行，未发 halt/resume/ndmreset，也未重载程序：

1. 直接通过 DMI 的 SBCS / SBADDRESS0 / SBDATA0 访问同一地址，读到固件 PASS `0x600d0001`。
2. 通过同一路径读出的十个最终输出全部与样本0 golden 一致，说明该次 CPU/NPU 推理已经完成。
3. 仅改变 OpenOCD 地址翻译模式，对同一地址重复四次高层读取：

| 翻译模式 | 高层 read_memory | 前后 DMSTATUS |
| --- | --- | --- |
| sw | 失败：priv 读取错误 | 0x30c82 / 0x30c82 |
| off | 成功：0x600d0001 | 0x30c82 / 0x30c82 |
| sw | 失败：priv 读取错误 | 0x30c82 / 0x30c82 |
| off | 成功：0x600d0001 | 0x30c82 / 0x30c82 |

DMSTATUS 的 halted 位均为0、running 位均为1。原始数据与诊断程序见
`npu/reports/ego1_board_20261116/running-sba-diagnosis.json` 和同目录 Python 原件。

## 软件原因与修正

本机 OpenOCD 为 `0.12.0+dev-04406-g10b7a647d`，默认 `virt2phys_mode=sw`。
其 `riscv_rw_memory` 在发出实际内存访问前调用地址翻译；`riscv_mmu` 先读取
`priv` / `mstatus`。CPU 运行时该寄存器访问失败，导致高层读写提前返回错误。
因此 `riscv set_mem_access sysbus` 本身不足以关闭前面的地址翻译。
暂停 CPU 后，OpenOCD 可以完成这些寄存器读取，因此之前的暂停方案能够通过。

源代码核对对应 OpenOCD 提交 `10b7a647da03cb64fd25db76261712c388ad6468`：
[`riscv_mmu`](https://github.com/riscv/riscv-openocd/blob/10b7a647da03cb64fd25db76261712c388ad6468/src/target/riscv/riscv.c#L3016)。
源文件哈希及关键位置另存于同一证据目录的 `openocd-source-audit.json`。

本项目是裸机程序，加载器使用 SRAM/MMIO 物理地址，正确设置为：

```tcl
riscv set_mem_access sysbus
riscv virt2phys_mode off
```

已同时加入 `npu/debug/target.cfg` 与 PC 脚本的初始化，确保新启动和已启动的服务器都使用
物理地址访问。主机回归增加配置顺序检查，共17项通过。初始加载之后仍禁止显式 halt/resume，
每帧前后通过 DMSTATUS 检查 CPU 状态。

这组对照定位的是本次复现的 priv 错误，不能据此推导任意版本的全部并发场景都无硬件缺陷。
本次变更限于 OpenOCD 配置与加载器初始化。

## 压力验证

修正后在实体板上全部通过，运行阶段未使用暂停/恢复回退：

| 测试 | 推理数 | 系统复位后完整加载批次 |
| --- | ---: | ---: |
| 单次推理 | 1 | 1 |
| 复位后重载推理 | 20 | 20 |
| 连续推理 | 2000，两批各1000 | 2 |
| 合计 | **2021** | **23** |

逐帧核对全部十个输出、CPU分类和完成序号；两批连续记录均无缺号、重号或槽位错误。
最后一批结束后，在CPU仍运行时读取硬件计数：Matrix 13000、CNN 212000，
分别等于13×1000和212×1000；SBCS错误位为零，固件结果为PASS。
最终记录见[validation.json](../../reports/ego1_board_20261116/validation.json)。
输入为十张固定 golden 样本的顺序变化，不是完整 MNIST；板级 DMSTATUS 是采样检查，
逐周期 CPU 未 halt 的断言由此前 ASIC/FPGA 各200帧 SoC 仿真提供。

失败与修正后结果分别保留。JTAG/USB/主机控制时间不计作纯 NPU 推理延迟。

WSL 连接时需先保持一个 Ubuntu 终端或进程运行，再执行 `usbipd attach --wsl --busid ...`。
总线编号以实际枚举为准；板载0403:6010用于配置，外接0403:6014才是本次RISC-V调试链路。
