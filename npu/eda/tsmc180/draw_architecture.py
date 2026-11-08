"""Draw the current NPU architecture as editable SVG and PNG."""

from pathlib import Path
import html, subprocess, json, hashlib
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "npu/docs/images"
W, H = 2240, 1940
im = Image.new("RGB", (W, H), "#0f172a")
d = ImageDraw.Draw(im)
fontfile = "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc"
svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
    f'<rect width="{W}" height="{H}" fill="#0f172a"/>',
]


def text(x, y, t, size=25, col="#e2e8f0"):
    for i, line in enumerate(t.split("\n")):
        yy = y + i * (size + 12)
        d.text((x, yy), line, font=ImageFont.truetype(fontfile, size), fill=col)
        svg.append(
            f'<text x="{x}" y="{yy + size}" font-family="Noto Sans CJK SC,sans-serif" font-size="{size}" fill="{col}">{html.escape(line)}</text>'
        )


def box(x, y, w, h, title, body="", col="#60a5fa", size=25):
    d.rounded_rectangle((x, y, x + w, y + h), radius=14, fill="#1e293b", outline=col, width=2)
    svg.append(
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="#1e293b" stroke="{col}" stroke-width="2"/>'
    )
    text(x + 20, y + 15, title, 28, col)
    if body:
        text(x + 20, y + 63, body, size)


def line(points, col="#60a5fa", arrow=True):
    d.line(points, fill=col, width=4)
    svg.append(
        '<polyline points="'
        + " ".join(f"{x},{y}" for x, y in points)
        + f'" fill="none" stroke="{col}" stroke-width="4"/>'
    )
    if arrow:
        x, y = points[-1]
        a, b = points[-2]
        dx = x - a
        dy = y - b
        l = (dx * dx + dy * dy) ** 0.5
        ux, uy = dx / l, dy / l
        tri = [
            (x, y),
            (x - 14 * ux + 7 * uy, y - 14 * uy - 7 * ux),
            (x - 14 * ux - 7 * uy, y - 14 * uy + 7 * ux),
        ]
        d.polygon(tri, fill=col)
        svg.append('<polygon points="' + " ".join(f"{a},{b}" for a, b in tri) + f'" fill="{col}"/>')


text(55, 28, "mynpu 详细架构｜独立计算核 + 软件任务调度 + 共享存储", 42)
text(
    55,
    90,
    "当前配置：CNN FIFO 8 / Matrix FIFO 8 / Vector FIFO 8 · RF 256B · SRAM 16KB · 50MHz目标",
    25,
    "#94a3b8",
)
box(
    55,
    160,
    430,
    190,
    "芯片接口 / JTAG调试",
    "9个信号PAD：CLK / RESET / START\nTCK / TMS / TDI / TDO / IRQ / HALTED\nDebug Module：SBA、halt/resume/step",
    size=21,
)
box(
    555,
    160,
    440,
    190,
    "CV32E40P CPU",
    "SRAM取指；普通load/store访问数据\nMMIO配置、任务提交、依赖同步\nIRQ16 Matrix / 17 Vector / 18 CNN",
    size=23,
)
box(
    1065,
    160,
    1120,
    190,
    "控制与任务入口  ·  CPU经XBAR译码访问MMIO",
    "独立完成/错误IRQ；只读启动编号、执行位置、量化采样/写应答计数\nCNN / Vector / QT01配置可运行中改写，时机由软件负责\n独立DMA及外部流接口已删除；保留测试host，9信号PAD的程序与输入统一经JTAG SBA装载",
    col="#c084fc",
    size=24,
)
line([(485, 240), (555, 240)])
line([(995, 240), (1065, 240)], "#c084fc")
text(492, 182, "调试", 19)
text(55, 390, "任务执行层：管理地址、循环、预取、程序PC与访存握手", 30, "#c084fc")
xs = [55, 790, 1525]
box(
    xs[0],
    450,
    660,
    310,
    "CNN Stream  ·  npu_stream / control / engine",
    "8项 × 32bit任务；每任务1～16位置\n3行 × 3words循环窗口 = 36B\n48bit行窗口选择；双份9B权重；返回直通\n跨通道部分和复用RF；4项结果位置标签\n末通道经弹性QT01；连续INT8合并写，INT32可旁路",
    col="#fb923c",
    size=26,
)
box(
    xs[1],
    450,
    660,
    310,
    "Matrix Stream  ·  npu_matrix_stream",
    "8项 × 96bit任务；含精度、间距、lda/ldb\nSRAM / RF / FIFO均支持4×4外积\n8×32bit操作数暂存；按需去重/复用\nRF并行读A/B；SRAM应答同拍续发\nK≤256；FC用K144；量化INT8可合并写回",
    col="#c084fc",
    size=26,
)
box(
    xs[2],
    450,
    660,
    310,
    "Vector Stream  ·  npu_vector_stream",
    "8项 × 99bit任务；标量与打包独立\nVPG3程序表实时读；PC + 4×32bit寄存器\nLD32复用ALU；打包与结果共用缓冲\n经xbar读取RF / SRAM或流FIFO\n乘法锁存数据与模式，分两拍；SIMD8仍四路并行",
    col="#2dd4bf",
    size=26,
)
for x in xs:
    line([(x + 330, 425), (x + 330, 450)], "#c084fc")
for x in xs:
    line([(x + 330, 760), (x + 330, 815)], "#2dd4bf")
    text(x + 350, 770, "操作数 / 运算控制 ↓  结果 ↑", 18, "#2dd4bf")
box(
    55,
    815,
    660,
    205,
    "CNN纯计算核  ·  DOT9",
    "9路 signed9激活 × signed8权重\n输入零点扣除 / mask / seed / INT32累加\nready/valid、emit、flush；无地址或量化",
    col="#fb923c",
    size=25,
)
box(
    790,
    815,
    660,
    205,
    "Matrix纯计算核  ·  4×4外积",
    "16路INT8 / INT16外积乘加\n16个INT32累加器；行列mask处理尾块\n按索引加旧D / 导出结果；无地址或循环",
    col="#c084fc",
    size=25,
)
box(
    1525,
    815,
    660,
    205,
    "Vector纯计算核  ·  通用整数ALU",
    "MUL32 / MULH / MULHU；32bit加法与进位\n单字 / 双字右移、舍入、逻辑与min/max\n单ALU：INT32 / 4×INT8 SIMD；量化用通用指令",
    col="#2dd4bf",
    size=25,
)

text(875, 1033, "任意单元 → xbar流FIFO → 任意单元（空队列直接转发）", 19, "#2dd4bf")
box(
    55,
    1080,
    2130,
    175,
    "数据通路入口  ·  6个普通master + 4条流通道 + RF gather / sink",
    "M0 CPU数据  |  M1 CNN  |  M2 Vector  |  M3 Host / JTAG SBA共享  |  M4 CPU取指  |  M5 Matrix\nCNN / Matrix / Vector共9个逻辑gather槽，共享8个RF物理bank。\n本图控制箭头表示逻辑关系；实际CPU配置读写也经过XBAR。CNN / Matrix可直连QT01，量化输入不经过XBAR。",
    col="#60a5fa",
    size=24,
)
for x in xs:
    line(
        [
            (x + 45, 760),
            (x + 45, 795),
            (x + 10, 795),
            (x + 10, 1060),
            (x + 110, 1060),
            (x + 110, 1080),
        ]
    )
box(
    55,
    1320,
    1310,
    245,
    "XBAR：地址路由 / 流FIFO / 存储仲裁",
    "4条流FIFO：每条8×32bit，地址0x80006000 + channel×0x100\n两块SRAM直接访问；无tag / 填充 / 失效或命中路径\n写流地址即发送，读同一地址即接收；满/空时反压，无RF中转\nMMIO分发到控制寄存器 / CNN / Debug / Boot",
    col="#60a5fa",
    size=27,
)
box(
    1435,
    1320,
    750,
    245,
    "XBAR内部共享RF  ·  npu_data_regfile",
    "256B = 8个单端口物理bank\n普通访问：2条逻辑lane，含RF写回共7个请求者\n三个单元共享gather；CNN独立RF写回\n逐端口译码；按bank掩码轮询与广播",
    col="#fbbf24",
    size=24,
)
line([(710, 1255), (710, 1320)])
line([(1810, 1255), (1810, 1320)], "#fbbf24")
box(
    55,
    1630,
    620,
    155,
    "SRAM bank 0  ·  8KB",
    "2048×32bit单端口宏\n0x80000000 – 0x80001FFF",
    size=25,
)
box(
    745,
    1630,
    620,
    155,
    "SRAM bank 1  ·  8KB",
    "2048×32bit单端口宏\n0x80002000 – 0x80003FFF",
    size=25,
)
line([(360, 1565), (360, 1630)])
line([(1050, 1565), (1050, 1630)])
box(
    1435,
    1630,
    750,
    155,
    "RF软件管理地址区",
    "0x80004000 – 0x800040FF\n小激活 / 部分和 / 临时权重；由软件显式暂存",
    col="#fbbf24",
    size=24,
)
line([(1810, 1565), (1810, 1630)], "#fbbf24")
text(
    55,
    1830,
    "并行边界：CNN / Matrix / Vector可并行，任意有向连接经xbar FIFO转发；CNN读请求、RF gather、计算与写回重叠，各主端口受bank冲突和FIFO反压约束。",
    25,
    "#2dd4bf",
)
text(
    55,
    1885,
    "当前：20,728周期/图 · SYNC v2 / SD95 / VPG3 · 新版综合见throughput-optimization验证报告；本轮未重跑完整PNR。",
    22,
    "#94a3b8",
)
svg.append("</svg>")
(OUT / "architecture-detailed.svg").write_text("\n".join(svg))
im.save(OUT / "architecture-detailed.png")
files = [
    "npu/rtl/top/npu_core.sv",
    "npu/rtl/control/npu_mmio.sv",
    "npu/rtl/interconnect/xbar.sv",
    "npu/rtl/interconnect/xbar_stream.sv",
    "npu/rtl/common/npu_addr_pkg.sv",
    "npu/rtl/interconnect/npu_data_regfile.sv",
    "npu/rtl/common/npu_rr_select.sv",
    "npu/rtl/common/npu_store_pack.sv",
    "npu/rtl/interconnect/npu_multi_read.sv",
    "npu/rtl/cnn/npu_stream_pkg.sv",
    "npu/rtl/cnn/npu_stream.sv",
    "npu/rtl/cnn/npu_stream_control.sv",
    "npu/rtl/cnn/npu_stream_engine.sv",
    "npu/rtl/cnn/npu_cnn.sv",
    "npu/rtl/matrix/npu_matmul.sv",
    "npu/rtl/matrix/npu_matrix_stream.sv",
    "npu/rtl/quant/npu_shared_quant.sv",
    "npu/rtl/vector/npu_vector.sv",
    "npu/rtl/vector/npu_vector_stream.sv",
    "npu/build_config.json",
]
(OUT / "architecture-detailed.source.json").write_text(
    json.dumps(
        {
            "scope": "Logical architecture, not physical placement; arrows show interface relationships",
            "source_sha256": {
                f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files
            },
        },
        indent=2,
    )
    + "\n"
)
print(OUT / "architecture-detailed.png")
