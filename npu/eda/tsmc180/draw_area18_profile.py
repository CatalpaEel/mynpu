"""Export standalone plots for exact mapped area and observational cycle profiles."""

import json
from pathlib import Path
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "npu/docs/images"
OUT.mkdir(exist_ok=True)
font = "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc"
font_manager.fontManager.addfont(font)
plt.rcParams.update(
    {
        "font.family": font_manager.FontProperties(fname=font).get_name(),
        "axes.unicode_minus": False,
        "svg.fonttype": "none",
        "font.size": 10,
    }
)
a = json.loads((ROOT / "npu/reports/area18_distribution.json").read_text())
p = json.loads((ROOT / "npu/reports/area18_blocking_profile.json").read_text())["variants"]


def save(fig, name):
    fig.savefig(OUT / (name + ".png"), dpi=180, bbox_inches="tight")
    fig.savefig(OUT / (name + ".svg"), bbox_inches="tight")
    plt.close(fig)


labels = {
    "SRAM": "两块 SRAM",
    "XBAR": "XBAR（含 RF 与流 FIFO）",
    "CPU": "CPU",
    "Matrix compute": "Matrix 计算核",
    "MMIO / queues": "MMIO / 任务队列",
    "CNN Stream": "CNN Stream",
    "Quantizer": "共享量化",
    "Matrix Stream": "Matrix Stream",
    "Vector compute": "Vector 计算核",
    "JTAG / debug": "JTAG / Debug",
    "Shared / unattributed": "共享 / 无法溯源",
    "Vector Stream": "Vector Stream",
    "CNN compute": "CNN 计算核",
}
rows = sorted(a["buckets"].items(), key=lambda kv: -kv[1]["area_mm2"])
fig, ax = plt.subplots(figsize=(10, 7))
for i, (key, b) in enumerate(rows):
    color = (
        "#94a3b8"
        if key == "Shared / unattributed"
        else "#2563eb"
        if key in ["SRAM", "XBAR"]
        else "#16a34a"
        if "Stream" in key
        else "#f59e0b"
    )
    ax.barh(i, b["area_mm2"], color=color)
    ax.text(
        b["area_mm2"] + 0.012,
        i,
        f"{b['area_mm2']:.6f}  ({b['percent']:.2f}%)",
        va="center",
        fontsize=9,
    )
ax.set_yticks(range(len(rows)), [labels[k] for k, _ in rows])
ax.invert_yaxis()
ax.set_xlim(0, 1.06)
ax.set_xlabel("映射 Cell Area / mm²")
ax.set_title("18ns＋门控：最终网表 2.515488mm² 的面积归属", pad=15)
ax.spines[["top", "right"]].set_visible(False)
fig.text(
    0.01,
    0.005,
    "按存续实例名前缀归属；模块值为可识别部分下界。含两块SRAM，不含PAD/CTS/布线。",
    fontsize=9,
)
fig.tight_layout(rect=(0, 0.025, 1, 1))
save(fig, "area18-distribution")
if "hierarchy_reference" in a:
    h = a["hierarchy_reference"]
    cn = {
        "SRAM macros": "两块SRAM",
        "XBAR": "XBAR（RF / FIFO / 仲裁）",
        "Matrix": "Matrix（计算＋Stream）",
        "CPU": "CPU",
        "CNN": "CNN（计算＋Stream）",
        "MMIO / task queues": "MMIO / 任务队列",
        "Vector": "Vector（计算＋Stream）",
        "Shared quantizer": "共享QT01",
        "JTAG / debug": "JTAG / Debug",
        "Top / core glue": "顶层连接逻辑",
    }
    rows = sorted(h["buckets"].items(), key=lambda kv: -kv[1]["area_mm2"])
    fig, ax = plt.subplots(figsize=(10, 6))
    for i, (key, b) in enumerate(rows):
        ax.barh(i, b["area_mm2"], color="#2563eb" if key in ["SRAM macros", "XBAR"] else "#16a34a")
        ax.text(
            b["area_mm2"] + 0.012,
            i,
            f"{b['area_mm2']:.6f} ({b['percent_total']:.2f}%)",
            va="center",
            fontsize=9,
        )
    ax.set_yticks(range(len(rows)), [cn.get(k, k) for k, _ in rows])
    ax.invert_yaxis()
    ax.set_xlim(0, 1.06)
    ax.set_xlabel("映射 Cell Area / mm²")
    ax.set_title("18ns＋门控：保留单元边界的统计重综合 2.507805mm²", pad=15)
    ax.spines[["top", "right"]].set_visible(False)
    fig.text(
        0.01,
        0.005,
        "同RTL的独立统计综合；与已冻结最终网表2.515488mm²分开列示。含SRAM，不含PAD/PNR。",
        fontsize=9,
    )
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    save(fig, "area18-hierarchy-distribution")
fig, axs = plt.subplots(2, 1, figsize=(12, 8))
views = [
    (
        "CPU_BLOCK_PROFILE",
        [
            ("other_awake", "其他活跃（含轮询）", "#64748b"),
            ("fetch", "取指等待", "#f59e0b"),
            ("lsu_mmio", "MMIO访存等待", "#ef4444"),
            ("load_hazard", "load-use停顿", "#8b5cf6"),
            ("lsu_sram", "SRAM访存等待", "#38bdf8"),
            ("wfi", "WFI睡眠", "#16a34a"),
        ],
        "CPU系统时钟周期：互斥优先分类",
    ),
    (
        "CPU_SOFTWARE_PROFILE",
        [
            ("work", "非轮询程序PC", "#2563eb"),
            ("queue_poll", "队列空间轮询PC", "#ef4444"),
            ("completion_poll", "任务完成轮询PC", "#f59e0b"),
            ("front_end", "ID无有效指令", "#94a3b8"),
            ("wfi", "WFI睡眠", "#16a34a"),
        ],
        "软件PC占用：与上图是不同视角，不能跨图相加",
    ),
]
for ax, (view, keys, title) in zip(axs, views):
    starts = [0, 0]
    for key, label, color in keys:
        vals = [p[v]["profile"][view]["mean"][key] for v in ["default", "quant"]]
        ax.barh([0, 1], vals, left=starts, label=label, color=color, height=0.5)
        for i, value in enumerate(vals):
            if value > 1100:
                ax.text(
                    starts[i] + value / 2,
                    i,
                    f"{value:,.0f}",
                    ha="center",
                    va="center",
                    color="white",
                    fontsize=10,
                )
        starts = [starts[i] + vals[i] for i in range(2)]
    for i, value in enumerate(starts):
        ax.text(value + 150, i, f"{value:,.0f}", va="center")
    ax.set_yticks([0, 1], ["默认 Vector 后处理", "共享 QT01 后处理"])
    ax.invert_yaxis()
    ax.set_xlim(0, 32500)
    ax.set_xlabel("平均系统时钟周期 / 张（10张输入）")
    ax.set_title(title)
    ax.spines[["top", "right"]].set_visible(False)
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.23), ncol=3, frameon=False, fontsize=9)
fig.tight_layout(h_pad=5)
save(fig, "area18-software-blocking")
fig, axs = plt.subplots(2, 1, figsize=(12, 9))
keys = [
    ("cnn_issue", "MAC发射", "#16a34a"),
    ("cnn_input", "激活供数等待", "#f59e0b"),
    ("cnn_weight", "权重等待", "#8b5cf6"),
    ("cnn_seed", "部分和等待", "#64748b"),
    ("cnn_output", "结果反压", "#ef4444"),
    ("cnn_other", "CNN控制/切换", "#0e7490"),
]
for ax, variant in zip(axs, ["default", "quant"]):
    stages = p[variant]["profile"]["STAGE_PROFILE"]["stages_mean"][:5]
    bottom = [0] * 5
    for key, label, color in keys:
        vals = [s[key] for s in stages]
        ax.bar(range(5), vals, bottom=bottom, label=label, color=color)
        bottom = [bottom[i] + vals[i] for i in range(5)]
    vals = [s["cycles"] - s["cnn_busy"] for s in stages]
    ax.bar(range(5), vals, bottom=bottom, label="CNN非忙（含CPU/Vector）", color="#cbd5e1")
    for i, s in enumerate(stages):
        ax.text(i, s["cycles"] + 100, f"{s['cycles']:,.0f}", ha="center")
    ax.set_xticks(range(5), ["Conv1", "Conv2", "Conv3", "Conv4", "Conv5"])
    ax.set_ylabel("系统时钟周期 / 层")
    ax.set_title("默认 Vector 后处理" if variant == "default" else "共享 QT01 后处理")
    ax.set_ylim(0, max(s["cycles"] for s in stages) * 1.15)
    ax.spines[["top", "right"]].set_visible(False)
handles, names = axs[0].get_legend_handles_labels()
fig.legend(handles, names, loc="lower center", ncol=4, frameon=False, fontsize=9)
fig.suptitle("CNN逐层周期：忙周期按优先原因互斥划分", fontsize=14)
fig.tight_layout(rect=(0, 0.08, 1, 0.96))
save(fig, "area18-cnn-blocking")
print("Wrote three PNG/SVG plots")

import hashlib

files = [
    "npu/reports/area18_distribution.json",
    "npu/reports/area18_blocking_profile.json",
    "npu/tb/tb_mnist_blocking.sv",
    "npu/eda/tsmc180/draw_area18_profile.py",
]
(OUT / "area18-profile.source.json").write_text(
    json.dumps(
        dict(
            matplotlib_version=matplotlib.__version__,
            scope="Data plots; no physical placement",
            source_sha256={f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files},
        ),
        indent=2,
    )
    + "\n"
)
