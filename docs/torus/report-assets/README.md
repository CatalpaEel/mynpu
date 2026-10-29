# 图文报告资源

正文在上一级 `design-report.md`。`design-report.html` 内嵌图片，可单文件查看；PDF 为六页 A4。正文中的相对证据链接需要保留项目目录。

- 五张 SVG 为结构、调度和面积数据的解释性图形，由 `generate_figures.py` 生成。
- 四张终端 PNG 为真实 xterm 中显示的原报告摘录，未改写工具报告行。`capture_reports.py` 选择关键行；`screenshot-sources.json` 保存原文件、行号和 SHA256。
- `innovus-powerplan.png` 为 Innovus 恢复实际 `06_powerplan` 数据库后的画布导出。来源见 `innovus-capture-source.json`。不是放置／信号布线完成截图。
- 没有复制专有 PDK、SRAM 模型或数据库到本目录。

在项目根目录重建示意图和文档：

```bash
/usr/bin/python3.12 docs/torus/report-assets/generate_figures.py
build/torus/report-capture/venv/bin/python docs/torus/report-assets/build_report.py --pdf
```

该虚拟环境安装了 markdown、Pillow、Playwright，PDF 使用已安装的 Chromium channel。报告截图重拍需要 Pillow、xterm、xwininfo 和独立 X 显示；本次使用 `DISPLAY=:97` 的临时 Xvfb。不要使用该脚本覆盖其他正在使用的桌面。

本次只是读取已有后端结果并生成文档，没有重新综合或修改 RTL／软件。后端截图保留原始失败信息，不能据此宣称 2mm×2mm 放置或布线后 50MHz 已通过。
