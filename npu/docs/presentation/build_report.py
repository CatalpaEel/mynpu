"""Build the editable current-design report from measured project artifacts."""

from pathlib import Path
import json
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).parent
IM = ROOT / "npu/docs/images"
DATA = json.loads((ROOT / "npu/reports/window_prefetch_fullchip_validation.json").read_text())
assert DATA["timing_closure_strict"] and DATA["core_physical_closure"]["passed"]
prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BG = "101827"
FG = "F1F5F9"
MUT = "A8B8CA"
BLUE = "60A5FA"
TEAL = "2DD4BF"
ORANGE = "FB923C"
slides = []
fontpath = "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc"
if not Path(fontpath).exists():
    import subprocess

    fontpath = subprocess.check_output(["fc-match", "-f", "%{file}", ":lang=zh"]).decode()


def txt(x, y, w, h, text, size=22, color=FG, bold=False):
    sh = s.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = sh.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = Inches(0.03)
    tf.margin_top = Inches(0.02)
    for i, line in enumerate(text.split("\n")):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text = line
        p.font.size = Pt(size)
        p.font.bold = bold
        p.font.name = "Noto Sans CJK SC"
        p.font.color.rgb = RGBColor.from_string(color)
        p.space_after = Pt(9)
    draw.multiline_text(
        (x * 120, y * 120),
        text,
        font=ImageFont.truetype(fontpath, int(size * 120 / 72)),
        fill="#" + color,
        spacing=12,
    )
    return sh


def box(x, y, w, h, text, color=BLUE, size=21):
    sh = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y), Inches(w), Inches(h))
    sh.fill.solid()
    sh.fill.fore_color.rgb = RGBColor.from_string("1D2B40")
    sh.line.color.rgb = RGBColor.from_string(color)
    draw.rounded_rectangle(
        (x * 120, y * 120, (x + w) * 120, (y + h) * 120),
        radius=12,
        fill="#1D2B40",
        outline="#" + color,
        width=2,
    )
    txt(x + 0.12, y + 0.12, w - 0.24, h - 0.2, text, size, color)


def arrow(x, y, w=0.45):
    txt(x, y, w, 0.5, "→", 26, TEAL)


def pic(name, x, y, w, h):
    f = IM / name
    im = Image.open(f)
    ratio = min(w / im.width, h / im.height)
    ww = im.width * ratio
    hh = im.height * ratio
    s.shapes.add_picture(
        str(f),
        Inches(x + (w - ww) / 2),
        Inches(y + (h - hh) / 2),
        width=Inches(ww),
        height=Inches(hh),
    )
    im = im.convert("RGB").resize((int(ww * 120), int(hh * 120)))
    canvas.paste(im, (int((x + (w - ww) / 2) * 120), int((y + (h - hh) / 2) * 120)))


def new(title, section, source="npu/docs/window-prefetch.md"):
    global s, canvas, draw
    s = prs.slides.add_slide(prs.slide_layouts[6])
    s.background.fill.solid()
    s.background.fill.fore_color.rgb = RGBColor.from_string(BG)
    canvas = Image.new("RGB", (1600, 900), "#" + BG)
    draw = ImageDraw.Draw(canvas)
    txt(0.5, 0.27, 12, 0.35, section.upper(), 12, TEAL, True)
    txt(0.5, 0.84, 12.3, 0.8, title, 30, FG, True)
    txt(0.5, 7.09, 11.8, 0.26, "MYNPU  /  2026.11.05  /  " + source, 9, MUT)
    txt(12.3, 7.02, 0.6, 0.4, f"{len(prs.slides):02}", 15, TEAL)
    s.notes_slide.notes_text_frame.text = (
        "证据来源："
        + source
        + "\n当前版本：experiment/independent-units；20261105-window-prefetch-backend。数据与旧版torus/历史20k结果不可混用。"
    )


def end():
    canvas.save(OUT / f"slide-{len(prs.slides):02}.png")
    slides.append(canvas.copy())


def bullets(lines, x=0.65, y=2, w=12, size=23, gap=0.83):
    for i, t in enumerate(lines):
        txt(x, y + i * gap, w, 0.7, "• " + t, size)


new("mynpu：从灵活计算核到完整芯片实现", "DESIGN REVIEW", "npu/docs/window-prefetch-pnr.md")
txt(0.65, 2.0, 11, 1.0, "设计架构 · 软件执行流程 · 后端综合与布局布线", 28, MUT)
for x, a, b in [
    (0.65, "3 个独立计算核", "CNN / Matrix / Vector"),
    (4.85, "25,388 周期", "当前 MNIST 单图推理"),
    (9.05, "2 × 2 mm²", "含 PAD 的完整 die"),
]:
    box(x, 3.6, 3.65, 1.45, a + "\n" + b, size=22)
txt(0.65, 5.7, 12, 0.7, "50 MHz TT时序收敛；核心非filler面积 2.738033 mm²。", 25, TEAL)
end()
new("职责分层：CPU编排任务，算术核专注计算", "01 / ARCHITECTURE")
box(0.6, 2, 2.4, 1, "CPU / JTAG\n程序与调试")
arrow(3.1, 2.25)
box(3.65, 2, 3.2, 1, "MMIO / FIFO\n配置、提交、依赖")
arrow(7, 2.25)
box(7.55, 2, 5.1, 1, "外部 Stream / Issue\n地址、循环、预取、读写应答")
for x, a, b in [
    (0.65, "CNN Stream", "CNN：DOT9"),
    (4.9, "Matrix Stream", "Matrix：MAC"),
    (9.15, "Vector Stream", "Vector：通用整数ALU"),
]:
    box(x, 3.5, 3.5, 1.65, a + "\n↓\n" + b, size=20)
box(0.65, 5.6, 12, 1, "NMC  ↔  两块 SRAM + 共享 RF   |   CNN最终结果 → Vector流水后处理", TEAL, 22)
end()
new("三个计算核：小接口、通用运算、明确状态", "01 / ARCHITECTURE", "npu/docs/pure-compute.md")
for x, title, body in [
    (0.6, "CNN", "9路输入×权重乘加\n支持零点扣除与mask\nINT32累加 / seed / emit\n不承担地址与量化"),
    (
        4.85,
        "Matrix",
        "signed16×16 MAC\n供数侧支持packed INT8\nINT32累加与加数合并\nM/N/K循环位于外部",
    ),
    (9.1, "Vector", "通用整数ALU\n32×32→64、加法、移位\n舍入、比较、min/max\n量化由软件指令组合"),
]:
    box(x, 1.95, 3.65, 0.65, title, TEAL, 24)
    txt(x + 0.08, 2.9, 3.5, 2.9, body, 21)
txt(0.7, 6, 12, 0.7, "CNN / Matrix保留累加状态；Vector的PC与4×64bit临时寄存器位于Issue。", 21, MUT)
end()
new("存储分层：SRAM容量 + RF并行带宽 + 窗口复用", "01 / ARCHITECTURE")
for x, y, w, h, t in [
    (0.65, 2, 3.7, 1.4, "共享SRAM：16 KB\n2 × 2048 × 32bit\n程序 / 参数 / 大激活"),
    (4.8, 2, 3.7, 1.4, "NMC透明读缓存\n每SRAM bank 16 words\n合计128 B"),
    (8.95, 2, 3.7, 1.4, "软件管理RF：256 B\n8个单端口物理bank\n激活 / 权重 / 部分和"),
]:
    box(x, y, w, h, t, size=20)
bullets(
    [
        "RF gather最多3×32bit/cycle；同bank读写仍需仲裁。",
        "CNN有36B三行循环窗口，缓存当前字与后续预取字。",
        "独立RF写回入口可与SRAM读取、gather读取重叠。",
        "任务FIFO：CNN 16项，Matrix 8项，Vector 8项。",
    ],
    y=4,
    size=22,
    gap=0.65,
)
end()
new("MNIST：CPU启动后，逐层推进完整推理", "02 / SOFTWARE")
items = [
    "JTAG SBA装载\n程序 / 参数 / 输入",
    "CPU初始化\n检查能力与ABI",
    "五层卷积\nCNN → Vector",
    "全连接144→10\nMatrix → Vector",
    "CPU argmax\n完成状态 / 结果",
]
for i, t in enumerate(items):
    box(0.55 + i * 2.55, 2.3, 2.2, 1.5, t, size=19)
    if i < 4:
        arrow(2.79 + i * 2.55, 2.8, 0.4)
bullets(
    [
        "CPU程序在SRAM；当前程序像4608B，参数4052B。",
        "卷积共296个tile任务；FC共90个K16任务。",
        "软件控制数据布局、边界、任务顺序、依赖与Vector程序。",
    ],
    y=4.55,
    size=23,
    gap=0.7,
)
end()
new("一层卷积：先准备消费者，再持续提交tile", "02 / SOFTWARE", "npu/mnist/firmware.py")
steps = [
    ("01  配置", "CPU更新基址、步长、零点；相同参数不重复写。"),
    ("02  提交Vector", "指定输出地址、元素数和每通道常量，等待CNN流。"),
    ("03  提交CNN", "CPU读取32bit任务表，向有空位的FIFO连续提交。"),
    ("04  计算与累加", "Stream供窗口与权重；中间输入通道部分和写共享RF。"),
    ("05  后处理与同步", "末通道INT32结果流入Vector；完成后推进下一层。"),
]
for i, (a, b) in enumerate(steps):
    box(0.65, 1.85 + i * 0.91, 2.25, 0.7, a, size=20)
    txt(3.15, 1.95 + i * 0.91, 9.3, 0.65, b, 21)
end()
new(
    "软件控制粒度：配置程序 + 排队执行",
    "02 / SOFTWARE",
    "npu/mnist/firmware.py; npu/rtl/vector/npu_vector_stream.sv",
)
box(
    0.65,
    1.95,
    5.7,
    3.7,
    "CPU提交逻辑（示意）\n\nlw  t0, task_table_ptr\nsw  t0, stream_task_register\n检查队列余量 / 错误状态\n继续提交，层末等待完成",
    BLUE,
    23,
)
box(
    6.85,
    1.95,
    5.8,
    3.7,
    "Vector后处理（语义）\n\n读取每通道乘数和偏置\n乘加 → 舍入右移24位\n加输出零点 → max(ReLU阈值)\nmin(255) → 打包写回",
    TEAL,
    22,
)
txt(
    0.7, 6.05, 12, 0.65, "硬件任务层执行循环与握手；CPU无需每个MAC发命令。没有专用量化核。", 22, MUT
)
end()
new("搬运与计算重叠：收益来自供数，不是增加MAC", "02 / SOFTWARE")
for y, a, b, c in [
    (2.0, "SRAM普通口", "当前输入字", "预取后续输入字"),
    (3.0, "RF gather", "权重 / 部分和seed", "下一通道权重"),
    (4.0, "RF写回入口", "非末通道部分和", "与SRAM读取并行"),
    (5.0, "CNN → Vector", "DOT9产生最终结果", "Vector通用程序处理"),
]:
    txt(0.65, y + 0.1, 2.4, 0.6, a, 21, TEAL)
    box(3.1, y, 4.2, 0.72, b, size=20)
    arrow(7.45, y + 0.05)
    box(8.0, y, 4.65, 0.72, c, size=20)
txt(
    0.65, 6.25, 12, 0.6, "前两层暂存20B / 72B权重；RF容量仍256B。CNN与Matrix目前不能并行。", 21, MUT
)
end()
new("当前周期：25,388，主要瓶颈仍在供数", "02 / SOFTWARE")
vals = [
    ("Conv1", 2101),
    ("Conv2", 5541),
    ("Conv3", 5419),
    ("Conv4", 2421),
    ("Conv5", 2738),
    ("FC", 7029),
    ("Argmax", 139),
]
for i, (n, v) in enumerate(vals):
    y = 1.85 + i * 0.60
    txt(0.7, y, 1.2, 0.4, n, 19)
    box(2, y, max(0.12, v / 7029 * 6.1), 0.32, "", TEAL)
    txt(8.35, y, 1.3, 0.4, f"{v:,}", 19)
box(10, 2, 2.6, 2, "29,206\n↓ 13.07%\n25,388", TEAL, 26)
txt(9.9, 4.45, 2.85, 1.65, "目标 <20k\n当前尚未达到\n50MHz约0.508ms", 20, ORANGE)
txt(
    0.7,
    6.42,
    12,
    0.45,
    "CNN输入等待6,774周期；FC阶段7,029周期，A/B串行请求应答是关键开销。",
    20,
    MUT,
)
end()
new("后端路径：冻结输入，逐阶段验证到GDS", "03 / IMPLEMENTATION", "npu/docs/window-prefetch-pnr.md")
for i, t in enumerate(
    [
        "Genus\n核心综合",
        "9信号PAD\n封装与电源",
        "Innovus\n放置优化",
        "CTS\n建立时钟树",
        "详细布线\n后优化修复",
        "最终导出\nGDS / SPEF",
    ]
):
    x = 0.55 + i * 2.12
    box(x, 2.4, 1.85, 1.2, t, size=20)
    if i < 5:
        arrow(x + 1.85, 2.75, 0.3)
bullets(
    [
        "冻结RTL、固件、约束与来源哈希；核心网表与芯片网表分别验证。",
        "两块真实SRAM宏贴左侧上下角，引脚朝核心内部。",
        "导出GDS、DEF、网表、SDC、SPEF、SDF及可恢复数据库。",
    ],
    y=4.4,
    size=22,
    gap=0.73,
)
end()
new(
    "实际放置：SRAM贴角，PAD按端点优化",
    "03 / IMPLEMENTATION",
    "npu/docs/images/window-prefetch-place.source.json",
)
pic("window-prefetch-place.png", 0.5, 1.65, 8, 5.25)
box(9, 2, 3.6, 1.2, "2 × 2 mm²\n包含完整PAD环", TEAL, 24)
txt(
    9,
    3.6,
    3.6,
    2.7,
    "9个信号PAD\n28个供电/地/POC PAD\n4个角单元\n37个bond窗口\nPAD距离目标减少24.54%",
    20,
)
end()
new(
    "最终布线与模块位置：计算和供数分别着色",
    "03 / IMPLEMENTATION",
    "npu/docs/module-distribution.md",
)
pic("window-prefetch-module-map.png", 0.4, 1.65, 8, 5.25)
pic("window-prefetch-fullchip.png", 8.7, 1.8, 4.2, 3.5)
txt(
    8.8,
    5.45,
    4.0,
    1.25,
    "左：实例实际坐标与模块归属\n右：最终金属布线截图\n灰色包含filler与物理辅助单元",
    18,
    MUT,
)
end()
new(
    "面积演进：布局后核心仍低于3 mm²预算",
    "03 / IMPLEMENTATION",
    "npu/reports/window_prefetch_fullchip_validation.json",
)
for x, a, b in [
    (0.65, "2.666814 mm²", "旧版CNN精简综合快照"),
    (4.85, "2.725461 mm²", "当前核心综合，含SRAM"),
    (9.05, "2.738033 mm²", "当前布局后核心，含SRAM"),
]:
    box(x, 2, 3.65, 1.3, a + "\n" + b, TEAL, 22)
bullets(
    [
        "历史快照 → 当前综合约增加2.20%；包含RF写回与窗口预取等变化。",
        "布局后：标准单元1.935146 + 两块SRAM 0.802887 mm²。",
        "filler另计0.290260 mm²；PAD包含在4 mm² die内。",
        "标准单元利用率约87%；最终100%填充率包含filler，不是逻辑利用率。",
    ],
    y=3.85,
    size=22,
    gap=0.70,
)
end()
new(
    "时序收敛：保持接口约束，修复真实hold违例",
    "03 / IMPLEMENTATION",
    "npu/docs/window-prefetch-pnr.md",
)
for y, a, b, c in [
    (2, "放置后", "Setup +0.001 ns", "初期负裕量经放置优化消除"),
    (3, "CTS后", "Setup +0.016 ns", "Hold −0.502 ns，3条违例"),
    (4, "Hold修复", "延迟单元修复", "最差路径：boot_ready → CPU启动寄存器"),
    (5, "最终布线后", "Setup +0.352 ns", "Hold +0.031 ns；TNS=0，违例路径=0"),
]:
    box(0.65, y, 2.3, 0.72, a, size=22)
    txt(3.2, y + 0.08, 3.5, 0.6, b, 22, TEAL)
    txt(6.85, y + 0.08, 5.9, 0.6, c, 19)
txt(0.65, 6.3, 12, 0.5, "系统50MHz / JTAG 10MHz异步时钟；TT单角、captable RC、SI关闭。", 21, MUT)
end()
new(
    "验证结果与签核边界",
    "03 / IMPLEMENTATION",
    "npu/reports/window_prefetch_fullchip_validation.json",
)
box(0.65, 2, 5.8, 0.7, "已完成的工具检查", TEAL, 24)
txt(
    0.8,
    3,
    5.5,
    3.5,
    "几何DRC：0\n天线违例：0\n核心电源连通问题：0\n最终setup / hold违例：0\n映射与布线后芯片JTAG各34项通过\nGDS与导出文件完整性审计通过",
    21,
)
box(6.85, 2, 5.8, 0.7, "仍需保留的限制", ORANGE, 24)
txt(
    7,
    3,
    5.5,
    3.6,
    "VDDPST / VSSPST两条IO轨提示\nSRAM LEF的M7/M8 OBS被六层技术忽略\n单TT角，未开展多角SI签核\n功能网表仿真未反标SDF\n不等于foundry DRC/LVS、ESD或EMIR签核",
    21,
)
end()
new(
    "当前结论与后续优化优先级",
    "04 / NEXT STEPS",
    "npu/docs/window-prefetch.md; npu/docs/window-prefetch-pnr.md",
)
bullets(
    [
        "架构：三个独立算术核，外部任务层管理供数，量化由通用Vector程序实现。",
        "软件：窗口预取、RF权重暂存和并行写回使推理减少13.07%。",
        "物理：含PAD的2×2mm²已完成布线，50MHz TT时序收敛。",
    ],
    y=2,
    size=24,
    gap=0.95,
)
box(
    0.65,
    5.15,
    12,
    1.15,
    "下一步：Matrix打包数据复用与A/B预取 → CNN跨tile复用 → 评估资源扩充",
    TEAL,
    21,
)
end()
prs.save(OUT / "mynpu-design-review.pptx")
thumbs = Image.new("RGB", (1600, 225 * 4), "#172033")
for i, im in enumerate(slides):
    thumbs.paste(im.resize((400, 225)), ((i % 4) * 400, (i // 4) * 225))
thumbs.save(OUT / "overview.png")
print("Created", len(prs.slides), "slides:", OUT / "mynpu-design-review.pptx")
