# 独立GUI后端工作区生成工具

[完整教程](../../../docs/backend-gui-lab.md)是主项目内的维护入口。`workspace_tools/`是生成工作区用的模板，不在模板目录直接运行`lab.py`。

本服务器已准备好的实例：

```
/home/s2400012841/chip-fullstack-2026/mynpu-backend-gui-20261119
```

它尚未运行综合/PNR。打开该实例的`BACKEND-LAB.md`或`backend_lab/GUI-TUTORIAL.md`开始。实例是独立快照，主项目模板后续修改不会偷偷改变它。

要再创建一个新实例：

```bash
python3.12 npu/eda/tsmc180/gui_lab/prepare_workspace.py \
  --out ../mynpu-backend-gui-NEW --branch lab/backend-gui-NEW
```

生成器会创建Git worktree、保留当前未提交修改、冻结核心RTL和库哈希、准备GUI脚本及私有签核参考。不会运行Genus综合、Innovus实现或Calibre检查。输出目录必须不存在。

依赖本服务器的PDK、SRAM及已记录参考库。可用`--reference-lab5`、`--reference-pnr`指定等价的本地参考目录。外部规则、技术库、OA/GDS与运行结果不存入本源码包，生成实例中的`backend_lab/private`与`runs`均被Git忽略。

维护分工：

- `npu/docs/backend-gui-lab.md`：教程正文。
- `workspace_tools/lab.py`、`bin/`：运行器与GUI启动器。
- `workspace_tools/templates/pnr/`：少量GUI环境及SDC设置。
- `npu/eda/tsmc180/fullchip/`：主要PNR脚本的唯一维护来源，创建实例时冻结一份。
- `verified_main53655b5_20261118/`：已执行的ECO快照，不随意修改其内容或provenance。
- `workspace_tools/templates/signoff/`：签核驱动与SKILL，创建实例后改写为各自路径。
