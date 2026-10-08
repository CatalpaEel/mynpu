# mynpu

面向 ASIC 的 RV CPU + 唯一 8KB SRAM + NMC + Tiny MNIST NPU，使用 Vivado 2025.2、Artix-7 `xc7a35tcsg324-1` 验证。可选 NoC 使用相同节点硬件构建 mesh。

- [NPU 设计与验证](npu/README.md)
- [NoC 设计与验证](npu/noc/README.md)
- 最新验证结果：`npu/reports/mnist_validation.json`、`npu/reports/noc/validation.json`

```bash
git clone --recurse-submodules git@github.com:CatalpaEel/mynpu.git
cd mynpu/npu
```

`external/tiny_MNIST` 固定为测试所用模型版本；`external/lab3-ST` 包含 CPU 与 SRAM 源文件。构建缓存、Python 虚拟环境和历史实现实验不纳入版本管理。现有脚本中的 Vivado 环境入口为 `/home/zzh/vivado/config/env_2025.2.sh`，换机器时须调整该路径；部分项目文件及历史验证清单含本机绝对路径，重新构建会生成当前路径。

NoC 当前验证覆盖逻辑链路及外部 DDR 服务模型，尚未集成实际片间 PHY、DDR 控制器或验证 ASIC 面积。
