"""Audit 4x4 Matrix synthesis and compare with the measured dot-product design."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "npu/scripts"))
from sim_sources import macro_wrapper

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--hier-run", type=Path, required=True)
p.add_argument("--baseline-run", type=Path, required=True)
p.add_argument("--baseline-hier-run", type=Path, required=True)
a = p.parse_args()
runs = [
    a.run.resolve(),
    a.hier_run.resolve(),
    a.baseline_run.resolve(),
    a.baseline_hier_run.resolve(),
]
current = json.loads((ROOT / "npu/reports/matrix_outer4_validation.json").read_text())
previous = json.loads((ROOT / "npu/reports/shared_quant_validation.json").read_text())
assert current["passed"] and previous["passed"]
reports = []
manifests = []
libraries = []
for index, (run, label) in enumerate(zip(runs, ["flat", "hier", "baseline", "baseline_hier"])):
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text(), run
    assert "No unresolved references" in (run / "reports/unresolved.rpt").read_text(), run
    m = json.loads((run / "source_manifest.json").read_text())
    manifests.append(m)
    assert m["synth_period_ns"] == 16 and m["report_period_ns"] == 20 and m["effort"] == "low"
    reference = current["source_sha256"] if index < 2 else previous["sha256"]
    for name, digest in m["source_sha256"].items():
        if name.startswith("npu/rtl/"):
            assert digest == reference[name], (run, name, "functional regression mismatch")
            if index < 2:
                assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
        if name == "npu/rtl/top/npu_soc.sv":
            source = (
                (ROOT / name).read_text()
                if index < 2
                else subprocess.check_output(
                    ["git", "show", m["git_commit"] + ":" + name], cwd=ROOT, text=True
                )
            )
            assert hashlib.sha256(source.encode()).hexdigest() == digest
            assert (run / "inputs/npu_asic_top.sv").read_text() == macro_wrapper(
                source, top="npu_asic_top"
            )
        else:
            assert hashlib.sha256((run / "inputs" / name).read_bytes()).hexdigest() == digest, (
                run,
                name,
            )
    lib = json.loads((run / "library_manifest.json").read_text())
    libraries.append(lib)
    for name, digest in lib.items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest
    out = ROOT / f"npu/reports/matrix_outer4_area_{label}.json"
    subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("collect_module_area.py")),
            "--run",
            str(run),
            "--out",
            str(out),
        ],
        cwd=ROOT,
        check=True,
    )
    reports.append(json.loads(out.read_text()))
    if index < 2:
        (run / "status.json").write_text(
            json.dumps(
                dict(
                    completed=True,
                    current_rtl_verified=True,
                    matches_outer4_regressions=True,
                    libraries_verified=True,
                    pnr_performed=False,
                ),
                indent=2,
            )
            + "\n"
        )
assert manifests[0]["source_sha256"] == manifests[1]["source_sha256"]
assert manifests[2]["source_sha256"] == manifests[3]["source_sha256"]
assert all(lib == libraries[0] for lib in libraries)
normal, hier, baseline, baseline_hier = reports
qor = (runs[0] / "reports/qor.rpt").read_text()
match = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
assert match
clock = re.search(r"^sys_clk\s+([\d.]+)\s*$", qor, re.M)
assert clock and float(clock[1]) == 20000
slack = float(match[1]) / 1000
tns = float(match[2]) / 1000
violations = int(match[3])
path_text = (runs[0] / "reports/timing.rpt").read_text()
critical = [
    line.strip()
    for line in path_text.splitlines()
    if re.match(r"\s*(Path 1:|Startpoint:|Endpoint:)", line)
][:3]


def matrix_parts(report):
    rows = report["buckets"]["Matrix"]["instances"]
    return dict(
        compute_mm2=sum(row["area_um2"] for row in rows if row["instance"].endswith("i_matmul"))
        / 1e6,
        stream_mm2=sum(
            row["area_um2"] for row in rows if row["instance"].endswith("i_matrix_stream")
        )
        / 1e6,
        total_mm2=report["buckets"]["Matrix"]["area_mm2"],
    )


parts = matrix_parts(hier)
old_parts = matrix_parts(baseline_hier)
assert parts["compute_mm2"] > 0 and parts["stream_mm2"] > 0
area = normal["total_area_mm2"]
old = baseline["total_area_mm2"]
report = dict(
    passed=True,
    source_commit=manifests[0]["git_commit"],
    baseline_source_commit=manifests[2]["git_commit"],
    scope="TSMC180 TT Genus19 low effort; 16ns optimization/20ns report; two real SRAM macros included; excludes PAD/CTS/routing/filler/placement whitespace",
    normal=normal,
    hierarchy_preserved=hier,
    baseline=baseline,
    baseline_hierarchy_preserved=baseline_hier,
    cell_area_budget_mm2=manifests[0]["cell_area_budget_mm2"],
    area_budget_headroom_mm2=manifests[0]["cell_area_budget_mm2"] - area,
    total_area_increase_mm2=area - old,
    total_area_increase_percent=(area / old - 1) * 100,
    matrix_hierarchical=parts,
    baseline_matrix_hierarchical=old_parts,
    setup_slack_ns_at_50mhz=slack,
    setup_tns_ns_at_50mhz=tns,
    setup_violating_paths_at_50mhz=violations,
    setup_target_met=violations == 0 and slack >= 0,
    critical_path=critical,
    source_manifests_identical=True,
    libraries_verified=True,
    matches_functional_regression_rtl=True,
    pnr_performed=False,
    power_measured=False,
)
(ROOT / "npu/reports/matrix_outer4_area_validation.json").write_text(
    json.dumps(report, indent=2) + "\n"
)
current["ppa"].update(
    synthesis_measured=True,
    timing_measured=True,
    sta_scope="Genus pre-layout setup only; no physical timing signoff",
    area_report="npu/reports/matrix_outer4_area_validation.json",
    total_area_mm2=area,
    setup_slack_ns_at_50mhz=slack,
    pnr_measured=False,
)
(ROOT / "npu/reports/matrix_outer4_validation.json").write_text(
    json.dumps(current, indent=2, ensure_ascii=False) + "\n"
)
lines = [
    "# 4×4外积版综合面积与时序",
    "",
    f"RTL检查点 `{manifests[0]['git_commit'][:7]}`。与旧点积Matrix、同样带共享QT01的版本比较。",
    "",
    "| 项目 | 旧点积版 mm² | 4×4外积版 mm² |",
    "|---|---:|---:|",
    f"| 默认优化总面积 | {old:.6f} | {area:.6f} |",
    f"| 标准单元 | {baseline['standard_cell_area_mm2']:.6f} | {normal['standard_cell_area_mm2']:.6f} |",
    f"| 两块SRAM宏 | {baseline['buckets']['SRAM macros']['area_mm2']:.6f} | {normal['buckets']['SRAM macros']['area_mm2']:.6f} |",
    "",
    f"总面积增加 **{area - old:.6f}mm²（{(area / old - 1) * 100:.2f}%）**。包含两块SRAM，不含PAD、CTS、布线、filler或放置留白。",
    "",
    f"相对3mm²单元面积预算仅余 {3 - area:.6f}mm²；布线与时钟树后的完整芯片能否放下仍需PNR验证。",
    "",
    "| Matrix分项（保留计算核层级） | 旧点积版 mm² | 4×4外积版 mm² |",
    "|---|---:|---:|",
    f"| 纯计算核 | {old_parts['compute_mm2']:.6f} | {parts['compute_mm2']:.6f} |",
    f"| Stream供数/寻址/写回 | {old_parts['stream_mm2']:.6f} | {parts['stream_mm2']:.6f} |",
    f"| Matrix合计 | {old_parts['total_mm2']:.6f} | {parts['total_mm2']:.6f} |",
    "",
    f"保留层级版总面积为{hier['total_area_mm2']:.6f}mm²，默认版为{area:.6f}mm²；两版跨层级优化不同，分项不与默认总数混加。",
    "",
    "## 时序",
    "",
    f"使用与基线相同的TSMC180 TT库与约束：16ns优化、20ns报告。50MHz系统时钟综合setup slack **{slack:+.4f}ns**，TNS **{tns:.4f}ns**，违反路径 **{violations}**。",
    "这是综合、布局前时序估算，尚未执行新版本CTS、布线或物理时序签核。",
    "",
    "关键路径摘要：",
    "",
]
lines += ["- " + line for line in critical]
lines += ["", "## 模块面积（保留层级版）", "", "| 模块 | 面积 mm² |", "|---|---:|"]
for name, b in sorted(hier["buckets"].items(), key=lambda item: -item[1]["area_mm2"]):
    lines.append(f"| {name} | {b['area_mm2']:.6f} |")
lines += [
    "",
    "已逐项核对当前冻结RTL与20组功能回归、历史基线RTL与其功能报告、工艺库哈希及SRAM宏包装器。没有把新版本RTL与旧面积数字混用。",
    "",
    "[机器报告](../reports/matrix_outer4_area_validation.json)。原始报告：",
]
for run in runs:
    lines.append(f"- [{run.name}/area.rpt]({run}/reports/area.rpt)")
lines += [
    f"- [当前50MHz timing.rpt]({runs[0]}/reports/timing.rpt)",
    "",
    "复现汇总：",
    "",
    "```bash",
    f"python3.12 npu/eda/tsmc180/collect_outer4_area.py --run {runs[0]} \\",
    f"  --hier-run {runs[1]} --baseline-run {runs[2]} \\",
    f"  --baseline-hier-run {runs[3]}",
    "```",
    "",
]
(ROOT / "npu/docs/matrix-outer4-area.md").write_text("\n".join(lines))
print(
    json.dumps(
        {
            k: v
            for k, v in report.items()
            if k
            not in ["normal", "hierarchy_preserved", "baseline", "baseline_hierarchy_preserved"]
        },
        indent=2,
    )
)
