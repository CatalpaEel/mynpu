# 独立IRQ与故障唤醒

任务格式见[字节码布局](command-layout.md)和[LY01/EV01](layout-events.md)。本页记录IRQ机制；性能和当前验证使用[报告索引](../reports/README.md)，不沿用本页历史周期。

当前CPU本地中断分配如下。三路均为电平中断，完成与错误通过该单元的状态寄存器区分。

| CPU IRQ ID | 来源 | 拉高条件 |
|---|---|---|
| 16 | Matrix | mat_done或mat_error |
| 17 | Vector | vec_done或vec_error |
| 18 | CNN | cnn_done或cnn_fault |
| 31 | 原有boot唤醒 | 保留原设计 |

Matrix和CNN不再OR到同一个CPU IRQ。顶层irq_o仍为5bit，bit0/1/2依次是Matrix/Vector/CNN，bit3/4为0；不增加PAD接口。全局只读CSR **0x40000070=0x00070000** 报告三个本地IRQ位。CPU读`mip & 0x70000`辨认挂起来源，`mie`可独立屏蔽。

这是IRQ布局的ABI变更：旧二进制若将CNN按IRQ16等待，不能继续直接使用。已更新 `npu/mnist/artifacts` 默认固件、10个SRAM镜像，以及单图/连续流生成器与C头文件。旧算子、地址、队列深度和算术数据通路没有改变。

## 完成、错误与确认

- 每个任务成功结束后，completed加一、done置位，IRQ保持挂起；它不自动代表整层结束。
- Matrix/Vector运行时故障现在设置各自error并拉高自己的IRQ，即使没有成功完成事件，也能唤醒WFI。CNN原有故障IRQ保留。
- 三个单元CONTROL **bit3=1** 均可在运行/排队期间确认done，不取消任务、不修改完成计数、不清error。
- 原bit1清done/error保留。Matrix/Vector仍要求空闲才能使用bit1；运行中应使用bit3确认done。
- 同拍发生新完成/故障和软件确认、清除或提交时，**新硬件事件优先**，保持可观察的挂起状态；故障不会因为确认done被隐藏。
- IRQ为电平信号。多个完成事件可以合并为一次唤醒，软件要看完成票据，不能按唤醒次数数任务。

完成计数仍只统计成功任务。故障批次必须先处理error并退出原等待，不能继续盲等旧submitted目标，也不提供失败任务自动回滚。普通非法CSR访问若只产生总线错误，不等于必然产生某个任务IRQ。

## 固件等待

当前固件开启`mie[18:16]`，保留`mstatus.MIE=0`的轻量WFI唤醒方式，不新增trap handler。三个单元可各自确认done，因此上一版Matrix“第一次中断后尾部轮询”的限制已取消：

```text
target = submitted
loop:
    ACK_DONE(bit3)
    if ERROR: 进入失败处理
    if completed == target: 完成
    WFI
    跳回loop
```

清done后再检查票据，覆盖“完成在清除之前/同拍/检查后到WFI之前发生”的窗口。新事件设置优先也适用于使用真正ISR的程序。

默认通用Vector路径同时开启CNN/Vector的完成和故障唤醒。CNN供数和Vector消费并发时，确认两路done、检查两路error，队列满等待在确认后重读占用；不能只开CNN IRQ，否则Vector报错后可能让CNN堵在FIFO上。等待Vector前会确认已完全排空的CNN来源，避免旧电平反复唤醒。

C接口新增：

```c
NPU_IRQ_MATRIX       // 16
NPU_IRQ_VECTOR       // 17
NPU_IRQ_CNN          // 18
npu_irq_pending();   // 读mip中的三个来源
npu_irq_ack_done(NPU_MAT_CONTROL); // 运行中确认完成，不清错误
```


## 当前验证入口

默认配置和性能使用[项目首页](../../README.md)；当前版本的功能、综合、最终PNR及检查证据统一见[报告索引](../reports/README.md)。
