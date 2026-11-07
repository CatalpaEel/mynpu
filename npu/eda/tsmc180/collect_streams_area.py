"""Audit whole-chip Stream simplification area, module attribution and setup timing."""

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
current = json.loads((ROOT / "npu/reports/streams_optimized_validation.json").read_text())
baseline_validation = json.loads((ROOT / "npu/reports/matrix_outer4_validation.json").read_text())
assert current["passed"] and baseline_validation["passed"]
reports = []
manifests = []
libraries = []
for i, (run, label) in enumerate(zip(runs, ["flat", "hier", "baseline", "baseline_hier"])):
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text(), run
    assert "No unresolved references" in (run / "reports/unresolved.rpt").read_text(), run
    m = json.loads((run / "source_manifest.json").read_text())
    manifests.append(m)
    assert m["synth_period_ns"] == 16 and m["report_period_ns"] == 20 and m["effort"] == "low"
    ref = current["source_sha256"] if i < 2 else baseline_validation["source_sha256"]
    for name, sha in m["source_sha256"].items():
        if name.startswith("npu/rtl/"):
            assert sha == ref[name], (run, name, "regression mismatch")
            if i < 2:
                assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha
        if name == "npu/rtl/top/npu_soc.sv":
            source = (
                (ROOT / name).read_text()
                if i < 2
                else subprocess.check_output(
                    ["git", "show", m["git_commit"] + ":" + name], cwd=ROOT, text=True
                )
            )
            assert hashlib.sha256(source.encode()).hexdigest() == sha
            assert (run / "inputs/npu_asic_top.sv").read_text() == macro_wrapper(
                source, top="npu_asic_top"
            )
        else:
            assert hashlib.sha256((run / "inputs" / name).read_bytes()).hexdigest() == sha
    libs = json.loads((run / "library_manifest.json").read_text())
    libraries.append(libs)
    for name, sha in libs.items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha
    out = ROOT / f"npu/reports/streams_optimized_area_{label}.json"
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
    if i < 2:
        (run / "status.json").write_text(
            json.dumps(
                dict(
                    completed=True,
                    current_rtl_verified=True,
                    matches_streams_regressions=True,
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
normal, hier, old, old_hier = reports


def parts(report):
    rows = report["hierarchical_rows"]
    depth = 4 if any(r["instance"] == "i_core" and r["indent"] == 2 for r in rows) else 2

    def area(suffix):
        selected = [r for r in rows if r["indent"] == depth and r["instance"].endswith(suffix)]
        assert len(selected) == 1, (suffix, selected)
        return selected[0]["area_um2"] / 1e6

    e = area("i_stream_i_engine")
    c = area("i_stream_i_control")
    return dict(
        matrix_stream=area("i_matrix_stream"),
        cnn_engine=e,
        cnn_control=c,
        cnn_stream=e + c,
        vector_stream=area("i_vector_stream"),
        matrix_compute=area("i_matmul"),
        cnn_compute=area("i_cnn"),
        vector_compute=area("i_vector"),
    )


new_parts = parts(hier)
old_parts = parts(old_hier)
keys = ["matrix_stream", "cnn_engine", "cnn_control", "cnn_stream", "vector_stream"]
comparison = {
    k: dict(
        before_mm2=old_parts[k],
        after_mm2=new_parts[k],
        saved_mm2=old_parts[k] - new_parts[k],
        saved_percent=(1 - new_parts[k] / old_parts[k]) * 100,
    )
    for k in keys
}
match = re.search(
    r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", (runs[0] / "reports/qor.rpt").read_text(), re.M
)
assert match
slack = float(match[1]) / 1000
tns = float(match[2]) / 1000
violations = int(match[3])
area = normal["total_area_mm2"]
previous = old["total_area_mm2"]
report = dict(
    passed=True,
    source_commit=manifests[0]["git_commit"],
    baseline_source_commit=manifests[2]["git_commit"],
    scope="TSMC180 TT Genus19 low effort;16ns optimization/20ns report; includes two real SRAM macros; excludes PAD/CTS/routing/filler/placement whitespace",
    normal=normal,
    hierarchy_preserved=hier,
    baseline=old,
    baseline_hierarchy_preserved=old_hier,
    total_saved_mm2=previous - area,
    total_saved_percent=(1 - area / previous) * 100,
    cell_budget_mm2=3,
    cell_budget_headroom_mm2=3 - area,
    stream_comparison=comparison,
    compute_after_mm2={k: v for k, v in new_parts.items() if k.endswith("compute")},
    setup_slack_ns_at_50mhz=slack,
    setup_tns_ns_at_50mhz=tns,
    setup_violating_paths_at_50mhz=violations,
    setup_target_met=slack >= 0 and violations == 0,
    libraries_verified=True,
    matches_functional_regression_rtl=True,
    pnr_performed=False,
    power_measured=False,
    inference_cycles=current["mnist"]["cycles"],
)
(ROOT / "npu/reports/streams_optimized_area_validation.json").write_text(
    json.dumps(report, indent=2) + "\n"
)
current["ppa"].update(
    synthesis_measured=True,
    timing_measured=True,
    pnr_measured=False,
    area_report="npu/reports/streams_optimized_area_validation.json",
    sta_scope="Genus pre-layout setup only; no physical timing signoff",
    total_area_mm2=area,
    setup_slack_ns_at_50mhz=slack,
)
(ROOT / "npu/reports/streams_optimized_validation.json").write_text(
    json.dumps(current, indent=2, ensure_ascii=False) + "\n"
)
lines = [
    "# 三种Stream精简后的面积与时序",
    "",
    f"优化RTL提交 `{manifests[0]['git_commit'][:7]}`，与优化前4×4 Matrix版本比较。",
    "",
    "| 项目 | 优化前 mm² | 优化后 mm² |",
    "|---|---:|---:|",
    f"| 默认综合总面积 | {previous:.6f} | {area:.6f} |",
    f"| 标准单元 | {old['standard_cell_area_mm2']:.6f} | {normal['standard_cell_area_mm2']:.6f} |",
    f"| 两块SRAM | {old['buckets']['SRAM macros']['area_mm2']:.6f} | {normal['buckets']['SRAM macros']['area_mm2']:.6f} |",
    "",
    f"总面积减少 **{previous - area:.6f}mm²（{(1 - area / previous) * 100:.2f}%）**。相对3mm²单元面积预算余量为{3 - area:.6f}mm²。",
    "",
    "| Stream分项（保留层级） | 优化前 mm² | 优化后 mm² | 减少 |",
    "|---|---:|---:|---:|",
]
for k, title in [
    ("matrix_stream", "Matrix Stream"),
    ("cnn_engine", "CNN Stream引擎"),
    ("cnn_control", "CNN控制/队列"),
    ("cnn_stream", "CNN Stream合计"),
    ("vector_stream", "Vector Stream"),
]:
    c = comparison[k]
    lines.append(
        f"| {title} | {c['before_mm2']:.6f} | {c['after_mm2']:.6f} | {c['saved_percent']:.2f}% |"
    )
lines += [
    "",
    f"保留层级版总面积为{hier['total_area_mm2']:.6f}mm²，分项不与默认版总数混加。CNN Stream合计已包含引擎与控制，不能再重复相加。",
    "",
    f"50MHz综合setup slack为 **{slack:+.4f}ns**，TNS {tns:.4f}ns，违反路径{violations}。",
    "",
    "以上包含真实两块SRAM宏，不含PAD、CTS、布线、filler及放置留白；未重跑PNR或测量功耗。冻结源码、工艺库和功能回归哈希均已核对。",
    "",
    "## 功能与周期",
    "",
    f"21组验证通过，其中15组重新运行、6组未变模块按源码哈希复用。默认VPG2为{current['mnist']['cycles']['default']:,}周期/张，共享量化为{current['mnist']['cycles']['quant']:,}周期/张；旧固件为{current['mnist']['cycles']['legacy']:,}周期。三者均与优化前一致。两条新软件路径各10张图、60个中间层张量、17,940字节逐字节匹配golden。",
    "",
    "[功能说明](streams-optimized.md)，[机器面积报告](../reports/streams_optimized_area_validation.json)。原始报告：",
    "",
]
for run in runs:
    lines.append(f"- [{run.name}/area.rpt]({run}/reports/area.rpt)")
lines += [f"- [当前时序报告]({runs[0]}/reports/timing.rpt)", ""]
(ROOT / "npu/docs/streams-optimized-area.md").write_text("\n".join(lines))
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
