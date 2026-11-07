# 删除独立DMA：JTAG装载版本

后续版本已实现[统一xbar流转发](xbar-stream-routes.md)。本页描述删除DMA后的首个版本及其冻结测试，master数量等以最新架构为准。

当前RTL已删除三个独立DMA通道、DMA寄存器以及SoC外部RX/TX流接口。NMC普通master数为5：CPU数据、CNN/Matrix复用、Vector、Host/JTAG SBA、CPU取指。RF专用sink仍作为RF内部第6个普通请求者；gather保持3×32bit，容量仍256B。

CNN Stream、Matrix Stream和Vector Stream继续承担计算侧地址、预取、取数和写回，CPU程序及参数、输入统一可由JTAG SBA装载。测试host保留用于快速回归和竞争测试，9信号ASIC封装中仍绑零。

旧DMA的0x40000300、0x40000400、0x40000500页面保留为无效地址，NMC返回总线错误且不执行控制写入。现有Debug Module没有SBA总线错误输入，因此该错误不会转成SBCS的sberror；软件应避免访问这些页。测试观察NMC实际错误回复验证删除行为。

公开C头文件删除DMA描述符/API。原DMA流、复制、填充及连续流测试依赖已删除功能，旧测试源码仅作为历史记录；run_vcs对尚未迁移的旧DMA依赖suite明确拒绝，避免挂起。当前使用`jtag`验证真实串行装载推理，`latency`通过测试host预载后验证十张样本逐层整数结果与推理周期。后者的输入装载周期不是JTAG装载时间。

```sh
python3.12 npu/scripts/run_vcs.py --suite jtag --macro --tag YOUR_JTAG_TAG
python3.12 npu/scripts/run_vcs.py --suite latency --macro --tag YOUR_LATENCY_TAG
```

历史完整后端2.738033mm²、50MHz setup +0.352ns / hold +0.031ns属于删除DMA前冻结快照。本次没有重新综合/布局布线，不将历史数字当作新版本PPA。之前的PPT和后端分布图同样属于该历史快照，详细架构图已更新。

最终真实SRAM宏模型回归：JTAG 42项检查通过，十张MNIST共120项检查通过，推理均25,388周期。机器证据见[验证报告](../reports/jtag_only_validation.json)。
