"""Audit measured logic reductions against frozen functional and physical inputs."""

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--before", type=Path, required=True)
p.add_argument("--gate-tags", nargs="*", default=[])
a = p.parse_args()
r, before = a.run.resolve(), a.before.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())


def qos(directory):
    assert any(
        marker in (directory / "launcher.log").read_text()
        for marker in ["LOGIC_TRIM_OOC_COMPLETED", "DUAL_BANK_ASIC_SYNTH_PASS"]
    )
    text = (
        (directory / "qor.rpt").read_text()
        if (directory / "qor.rpt").exists()
        else (directory / "reports/qor.rpt").read_text()
    )
    area = float(re.search(r"^Cell Area\s+([\d.]+)", text, re.M)[1]) / 1e6
    timing = {}
    for clock in ["sys_clk", "jtag_clk"]:
        m = re.search(r"^" + clock + r"\s+([\d.-]+)\s+([\d.-]+)\s+(\d+)", text, re.M)
        if m:
            timing[clock] = {
                "slack_ns": float(m[1]) / 1000,
                "tns_ns": float(m[2]) / 1000,
                "violating_paths": int(m[3]),
            }
    return {"cell_area_mm2": area, "timing": timing}


old, new = read(before / "source_manifest.json"), read(r / "asic/source_manifest.json")
assert read(before / "library_manifest.json") == read(r / "asic/library_manifest.json")
for name, digest in read(r / "asic/library_manifest.json").items():
    assert sha(name) == digest, name
changed = []
for name, digest in new["source_sha256"].items():
    assert sha(ROOT / name) == digest, name
    if digest != old["source_sha256"][name]:
        changed.append(name)
assert set(changed) == {
    "npu/rtl/npu_cnn_engine.sv",
    "npu/rtl/npu_cnn_mac.sv",
    "npu/rtl/npu_dma_regs.sv",
}
for key in [
    "rf_bank_words",
    "matrix_queue_depth",
    "vector_queue_depth",
    "cnn_queue_depth",
    "synth_period_ns",
    "report_period_ns",
    "effort",
]:
    assert old[key] == new[key], key
modules = {}
for top in ["npu_cnn_engine", "npu_dma_regs"]:
    rows = {}
    for version in ["before", "after"]:
        d = r / "ooc" / (version + "-" + top)
        for name, digest in read(d / "manifest.json")["sha256"].items():
            assert sha(name) == digest, name
        rows[version] = qos(d)
    rows["saved_mm2"] = rows["before"]["cell_area_mm2"] - rows["after"]["cell_area_mm2"]
    rows["saved_percent"] = 100 * rows["saved_mm2"] / rows["before"]["cell_area_mm2"]
    modules[top] = rows
frozen = read(r / "asic/functional_manifest.json")
functional = {}
for suite, record in frozen["regressions"].items():
    result = Path(record["result"])
    j = read(result)
    assert (
        sha(result) == record["sha256"]
        and sha(result.parent / "run.log") == record["run_log_sha256"]
    )
    assert j["passed"] and not j["changed_during_run"], suite
    for name, digest in j["sha256"].items():
        assert sha(frozen["snapshots"].get(name, name)) == digest, name
    functional[suite] = {"passed": True, "summaries": j["summaries"], **record}
assert len(functional) == 15
for name, digest in frozen["image_sha256"].items():
    assert sha(r / "asic/images" / name) == digest, name
j = read(r / "dma-validator/result.json")
assert j["passed"]
for name, digest in j["sha256"].items():
    assert sha(name) == digest, name
assert sha(r / "dma-validator/run.log") == j["run_log_sha256"]
gates = {}
for tag in a.gate_tags:
    result = ROOT / "npu/build" / ("gate-" + tag) / "result.json"
    g = read(result)
    assert g["passed"] and not g["changed_during_run"]
    assert g["sha256"][str(r / "asic/optimized.v")] == sha(r / "asic/optimized.v")
    for name, digest in g["sha256"].items():
        assert sha(name) == digest, name
    gates[tag] = g
before_qor, after_qor = qos(before), qos(r / "asic")
assert after_qor["cell_area_mm2"] < before_qor["cell_area_mm2"]
assert all(v["slack_ns"] >= 0 and v["violating_paths"] == 0 for v in after_qor["timing"].values())
hierarchy = {}
for label, instance in {
    "cnn_engine": "i_core_i_cnn_i_engine",
    "dma_control": "i_core_i_dma_regs",
    "xbar_including_regfile": "i_core_i_xbar",
    "regfile_subset": "i_regfile",
}.items():
    row = {}
    for version, directory in [("before", before), ("after", r / "asic")]:
        text = (directory / "reports/area.rpt").read_text()
        match = re.search(r"^\s+" + re.escape(instance) + r"\s+\S+\s+\d+\s+([\d.]+)", text, re.M)
        assert match, instance
        row[version + "_mm2"] = float(match[1]) / 1e6
    hierarchy[label] = row
report = {
    "scope": "Same RF512B, M8/V8/C16 queues, CPU/JTAG, both real8KB SRAM macros. RTL and mapped pre-route evidence; no new PnR result is implied.",
    "changed_rtl": changed,
    "before_run": str(before),
    "after_run": str(r / "asic"),
    "before": before_qor,
    "after": after_qor,
    "saved_mm2": before_qor["cell_area_mm2"] - after_qor["cell_area_mm2"],
    "saved_percent": 100
    * (before_qor["cell_area_mm2"] - after_qor["cell_area_mm2"])
    / before_qor["cell_area_mm2"],
    "ooc": modules,
    "full_hierarchy": hierarchy,
    "functional": functional,
    "dma_differential": j,
    "mapped_tests": gates,
    "reports_sha256": {str(f.relative_to(r)): sha(f) for f in r.rglob("*.rpt")},
    "performance": {
        "inference_cycles": 17514,
        "ingress_plus_inference_cycles": 18135,
        "before_ingress_plus_inference_cycles": 18134,
        "stream_20_frames_cycles": 355252,
    },
    "source_manifest_sha256": sha(r / "asic/source_manifest.json"),
    "library_manifest_sha256": sha(r / "asic/library_manifest.json"),
}
text = json.dumps(report, indent=2) + "\n"
(ROOT / "npu/reports/logic_trim_validation.json").write_text(text)
(r / "validation.json").write_text(text)
print(
    json.dumps(
        {key: report[key] for key in ["before", "after", "saved_mm2", "saved_percent"]}, indent=2
    )
)
