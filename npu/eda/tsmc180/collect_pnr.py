"""Audit physical-run inputs and summarize actual timing, connectivity and DRC reports."""

import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--gate-tags", nargs="*", default=[])
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
m = json.loads((r / "manifest.json").read_text())
for group in ["input_sha256", "library_sha256"]:
    for path, digest in m[group].items():
        assert sha(path) == digest, path
synthesis = Path(m["synthesis"])
assert sha(synthesis / "source_manifest.json") == m["synthesis_manifest_sha256"]
assert sha(r / "netlist.v") == sha(synthesis / "optimized.v")
source_root = Path(m["build"]["source_root"])
for path, digest in m["build"]["source_sha256"].items():
    assert sha(source_root / path) == digest, path
stages = {}
for stage in ["init", "place", "pgfix", "cts", "route", "finish", "cleanup"]:
    log = r / (stage + ".log")
    if not log.exists():
        continue
    text = log.read_text()
    reports = {}
    for suffix in ["drc", "signal", "pg", "area", "footprint"]:
        path = r / "reports" / (stage + "_" + suffix + ".rpt")
        if path.is_file():
            content = path.read_text()
            reports[suffix] = {"path": str(path), "sha256": sha(path)}
            if suffix == "drc":
                match = re.search(r"Total (?:Violations|violations)\s*[:=]\s*(\d+)", content)
                reports[suffix]["violations"] = (
                    0
                    if "No DRC violations were found" in content
                    else int(match[1])
                    if match
                    else None
                )
            elif suffix in ["signal", "pg"]:
                match = re.search(r"(\d+) total info\(s\) created", content)
                reports[suffix]["issues"] = (
                    int(match[1])
                    if match
                    else 0
                    if re.search(
                        r"No .*violations|No .*problems|No .*errors|No .*nets.*unconnected",
                        content,
                        re.I,
                    )
                    else None
                )
            elif suffix == "footprint":
                for group in ["standard", "sram", "filler"]:
                    match = re.search(group + r"_bbox_area_um2\s+([\d.]+)", content)
                    if match:
                        reports[suffix][group + "_mm2"] = float(match[1]) / 1e6
    stages[stage] = {
        "command_completed": "PNR_STAGE_PASS " + stage in text,
        "log": str(log),
        "log_sha256": sha(log),
        "reports": reports,
    }
timing = {}
for path in (r / "reports").rglob("*.summary*"):
    content = gzip.open(path, "rt").read() if path.suffix == ".gz" else path.read_text()
    row = {}
    for label, key in [
        ("WNS (ns)", "wns_ns"),
        ("TNS (ns)", "tns_ns"),
        ("Violating Paths", "violating_paths"),
    ]:
        match = re.search(re.escape(label) + r":\|\s*([-\d.]+)", content)
        if match:
            row[key] = float(match[1])
    timing[str(path.relative_to(r))] = {**row, "sha256": sha(path)}
mapped = {}
for tag in a.gate_tags:
    path = source_root / "npu/build" / ("gate-" + tag) / "result.json"
    j = json.loads(path.read_text())
    assert j["passed"] and not j["changed_during_run"], tag
    assert j["sha256"][str(r / "outputs/routed.v")] == sha(r / "outputs/routed.v")
    for name, digest in j["sha256"].items():
        assert sha(name) == digest, name
    mapped[tag] = j
final_stage = "cleanup" if stages.get("cleanup", {}).get("command_completed") else "finish"
checks = stages.get(final_stage, {}).get("reports", {})
footprint = checks.get("footprint", {})
area = footprint.get("standard_mm2", 0) + footprint.get("sram_mm2", 0)
final_timing = {
    key: value
    for key, value in timing.items()
    if ("/clean_" in key if final_stage == "cleanup" else "/final" in key)
}
checks_clean = (
    len(final_timing) >= 2
    and all(
        value.get("wns_ns", -1) >= 0 and value.get("tns_ns", -1) == 0
        for value in final_timing.values()
    )
    and checks.get("drc", {}).get("violations") == 0
    and all(checks.get(key, {}).get("issues") == 0 for key in ["signal", "pg"])
)
report = {
    "run": str(r),
    "final_stage": final_stage,
    "tt_core_checks_clean": checks_clean,
    "nonfiller_cell_bbox_area_mm2": area,
    "within_3mm2_nonfiller_bbox_budget": 0 < area <= 3,
    "routed_functional_tests": mapped,
    "manifest_sha256": sha(r / "manifest.json"),
    "rtl_unchanged_from_synthesis": True,
    "scope": m["scope"],
    "all_report_sha256": {
        str(p.relative_to(r)): sha(p) for p in (r / "reports").rglob("*") if p.is_file()
    },
    "stages": stages,
    "timing": timing,
    "outputs_sha256": {
        str(path.relative_to(r)): sha(path) for path in (r / "outputs").iterdir() if path.is_file()
    },
    "limitations": [
        "Core only; no IO pads or package.",
        "TT single-corner RC captable analysis, not multi-corner signoff.",
        "SRAM LEF contains METAL7/8 obstructions absent from six-metal technology; ignored by tool.",
        "Macro antenna attributes are incomplete; Innovus checks do not establish foundry signoff.",
    ],
}
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
print(
    json.dumps(
        {"stages": {k: v["command_completed"] for k, v in stages.items()}, "timing": timing},
        indent=2,
    )
)
