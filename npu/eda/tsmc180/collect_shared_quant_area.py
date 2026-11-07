"""Audit frozen synth inputs, collect current module area and exact pre-quant comparison."""

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
a = p.parse_args()
runs = [a.run.resolve(), a.hier_run.resolve(), a.baseline_run.resolve()]
functional = json.loads((ROOT / "npu/reports/shared_quant_validation.json").read_text())
pre_quant = json.loads((ROOT / "npu/reports/vector_simd_validation.json").read_text())
assert functional["passed"] and pre_quant["passed"]
reports = []
manifests = []
libraries = []
for index, (run, label) in enumerate(zip(runs, ["flat", "hier", "baseline"])):
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (run / "launcher.log").read_text(), run
    assert "No unresolved references" in (run / "reports/unresolved.rpt").read_text(), run
    manifest = json.loads((run / "source_manifest.json").read_text())
    manifests.append(manifest)
    assert manifest["synth_period_ns"] == 16 and manifest["report_period_ns"] == 20
    assert manifest["effort"] == "low"
    reference = functional["sha256"] if index < 2 else pre_quant["source_sha256"]
    for name, digest in manifest["source_sha256"].items():
        if name.startswith("npu/rtl/"):
            assert digest == reference[name], (run, name, "regression mismatch")
            if index < 2:
                assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
        if name == "npu/rtl/top/npu_soc.sv":
            original = (
                (ROOT / name).read_text()
                if index < 2
                else subprocess.check_output(
                    ["git", "show", manifest["git_commit"] + ":" + name], cwd=ROOT, text=True
                )
            )
            assert hashlib.sha256(original.encode()).hexdigest() == digest
            assert (run / "inputs/npu_asic_top.sv").read_text() == macro_wrapper(
                original, top="npu_asic_top"
            )
        else:
            assert hashlib.sha256((run / "inputs" / name).read_bytes()).hexdigest() == digest
    lib = json.loads((run / "library_manifest.json").read_text())
    for name, digest in lib.items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest
    libraries.append(lib)
    out = ROOT / f"npu/reports/shared_quant_area_{label}.json"
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
    (run / "status.json").write_text(
        json.dumps(
            dict(
                completed=True,
                frozen_sources_verified=True,
                libraries_verified=True,
                matches_functional_regressions=True,
                current_rtl=index < 2,
                pnr_performed=False,
            ),
            indent=2,
        )
        + "\n"
    )
assert manifests[0]["source_sha256"] == manifests[1]["source_sha256"]
assert libraries[0] == libraries[1] == libraries[2]
normal, hierarchy, baseline = reports
match = re.search(
    r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", (runs[0] / "reports/qor.rpt").read_text(), re.M
)
assert match
quant = hierarchy["buckets"]["Shared quantizer"]["area_mm2"]
area = normal["total_area_mm2"]
previous = baseline["total_area_mm2"]
report = dict(
    passed=True,
    source_commit=manifests[0]["git_commit"],
    baseline_commit=manifests[2]["git_commit"],
    scope="Genus19 TSMC180 TT low effort;16ns optimization/20ns reporting; two real SRAM macros included; PAD/CTS/routing/filler/placement whitespace excluded",
    normal=normal,
    hierarchy_preserved=hierarchy,
    pre_quant_baseline=baseline,
    quantizer_hierarchical_area_mm2=quant,
    net_area_increase_mm2=area - previous,
    net_area_increase_percent=(area / previous - 1) * 100,
    setup_slack_ns_at_50mhz=float(match[1]) / 1000,
    setup_tns_ns_at_50mhz=float(match[2]) / 1000,
    setup_violating_paths_at_50mhz=int(match[3]),
    source_manifests_identical=True,
    matches_functional_regression_rtl=True,
    pnr_performed=False,
    power_measured=False,
    inference_cycles=functional["mnist"]["quant_cycles"],
)
(ROOT / "npu/reports/shared_quant_area_validation.json").write_text(
    json.dumps(report, indent=2) + "\n"
)
functional["ppa"].update(
    synthesis_measured=True,
    sta_measured=True,
    sta_scope="Genus pre-layout setup only, no physical signoff",
    note="Genus TT pre-layout setup measured at 50MHz; CTS/routing/signoff not performed.",
    area_report="npu/reports/shared_quant_area_validation.json",
)
(ROOT / "npu/reports/shared_quant_validation.json").write_text(
    json.dumps(functional, indent=2, ensure_ascii=False) + "\n"
)
lines = [
    "# 共享量化版综合面积",
    "",
    f"源码 `{manifests[0]['git_commit'][:7]}`，对照为加入量化前的 SIMD 检查点 `{manifests[2]['git_commit'][:7]}`。",
    "",
    "| 项目 | 面积 mm² |",
    "|---|---:|",
    f"| 当前默认优化总面积 | {area:.6f} |",
    f"| 标准单元 | {normal['standard_cell_area_mm2']:.6f} |",
    f"| 两块 SRAM 宏 | {normal['buckets']['SRAM macros']['area_mm2']:.6f} |",
    f"| 加量化前同配置总面积 | {previous:.6f} |",
    f"| 净增加（含接口改动） | {area - previous:.6f} |",
    "",
    f"相对基线净增加 {(area / previous - 1) * 100:.2f}%。保留层级版的共享量化模块自身为 **{quant:.6f}mm²**，包括参数寄存器、仲裁、乘法、舍入和裁剪。",
    "",
    f"默认版在20ns报告约束下，系统时钟setup slack **{float(match[1]) / 1000:+.4f}ns**，TNS {float(match[2]) / 1000:.4f}ns，违反路径{match[3]}。属于综合估算，尚未重新布局布线。",
    "",
    "模块分布使用保留层级版；它与默认优化版存在跨层级优化差异，分项不与默认版总数混加。",
    "",
    "| 保留层级版模块 | 面积 mm² |",
    "|---|---:|",
]
for name, value in sorted(hierarchy["buckets"].items(), key=lambda item: -item[1]["area_mm2"]):
    lines.append(f"| {name} | {value['area_mm2']:.6f} |")
lines += [
    "",
    f"保留层级版总计 {hierarchy['total_area_mm2']:.6f}mm²。以上包含两块SRAM，不含PAD、CTS、布线、filler和放置留白，不能据此确认2mm×2mm完整芯片能布下。",
    "",
    "三个运行均使用相同库、约束与低effort设置；冻结输入哈希、当前功能回归和历史SIMD回归已逐项核对。",
    "",
    "[机器报告](../reports/shared_quant_area_validation.json)。原始报告：",
]
for run in runs:
    lines.append(f"- [{run.name}/area.rpt]({run}/reports/area.rpt)")
lines += [
    "",
    "复现汇总：",
    "",
    "```bash",
    f"python3.12 npu/eda/tsmc180/collect_shared_quant_area.py --run {runs[0]} \\",
    f"  --hier-run {runs[1]} --baseline-run {runs[2]}",
    "```",
    "",
]
(ROOT / "npu/docs/shared-quant-area.md").write_text("\n".join(lines))
print(
    json.dumps(
        {
            k: v
            for k, v in report.items()
            if k not in ["normal", "hierarchy_preserved", "pre_quant_baseline"]
        },
        indent=2,
    )
)
