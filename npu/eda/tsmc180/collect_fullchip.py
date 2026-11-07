"""Collect native-PAD physical results without conflating native IO rails with routed core nets."""

import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--gate-tags", nargs="*", default=[])
a = p.parse_args()
r = a.run.resolve()
out = r / "mynpu/pnr"
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())
m = read(r / "manifest.json")
for name, digest in m["library_sha256"].items():
    assert sha(name) == digest, name
for name, digest in m["inputs_sha256"].items():
    assert sha(r / name) == digest, name
for name, digest in m.get("frozen_script_sha256", {}).items():
    assert sha(r / "scripts" / name) == digest, name
for name, digest in m["core_source_manifest"]["source_sha256"].items():
    assert sha(ROOT / name) == digest, name
stages = {}
for f in sorted((r / "logs").glob("*.json")):
    j = read(f)
    assert sha(f.with_suffix(".log")) == j["log_sha256"]
    j["reported_tool_errors"] = [
        line.strip()
        for line in f.with_suffix(".log").read_text(errors="replace").splitlines()
        if "**ERROR:" in line
    ]
    stages[f.stem] = j
# Keep full raw reports and hashes available; zero DRC is distinct from command completion.
checks = {}
for name in [
    "13_final_drc",
    "13_final_signal",
    "13_final_pg",
    "13_final_antenna",
    "13_final_place",
    "06_io_pg",
]:
    f = out / "reports" / (name + ".rpt")
    if not f.exists():
        continue
    text = f.read_text()
    row = {"path": str(f), "sha256": sha(f)}
    if name.endswith("drc"):
        match = re.search(r"Total Violations\s*:\s*(\d+)", text)
        row["violations"] = (
            0 if "No DRC violations were found" in text else int(match[1]) if match else None
        )
    if name.endswith(("signal", "pg")):
        match = re.search(r"(\d+) total info\(s\) created", text)
        row["reported_issues"] = (
            0 if "Found no problems or warnings" in text else int(match[1]) if match else None
        )
        row["summary"] = [
            line.strip() for line in text.splitlines() if "Problem(s)" in line or "Net " in line
        ][:30]
    checks[name] = row
timing = {}
placement = {}
for name in ["08_post_tie", "08_reclaimed", "10_cts", "11_legalized", "13_final"]:
    f = out / "reports" / (name + "_place.rpt")
    if not f.exists():
        continue
    text = f.read_text()
    unplaced = re.search(r"Number of Unplaced Instances = (\d+)", text)
    violations = re.search(r"Total instances with placement violations: (\d+)", text)
    density = re.search(r"Placement Density:([\d.]+)%", text)
    row = {
        "path": str(f),
        "sha256": sha(f),
        "unplaced_instances": int(unplaced[1]) if unplaced else None,
        "placement_violation_instances": int(violations[1]) if violations else 0,
        "density_percent": float(density[1]) if density else None,
        "scope": "Core placement legality; intentional IO/bond overlaps are audited separately.",
    }
    row["passed"] = row["unplaced_instances"] == 0 and row["placement_violation_instances"] == 0
    placement[name] = row
for f in (out / "reports").rglob("*.summary*"):
    text = gzip.open(f, "rt").read() if f.suffix == ".gz" else f.read_text()
    row = {}
    for label, key in [
        ("WNS (ns)", "wns_ns"),
        ("TNS (ns)", "tns_ns"),
        ("Violating Paths", "violating_paths"),
    ]:
        match = re.search(re.escape(label) + r":\|\s*([-\d.]+)", text)
        if match:
            row[key] = float(match[1])
    timing[str(f.relative_to(out))] = {**row, "sha256": sha(f)}
footprint = {}
f = out / "reports/13_implemented_footprint.rpt"
if f.exists():
    for line in f.read_text().splitlines():
        if line.startswith("#"):
            continue
        key, value = line.split()
        footprint[key] = float(value)
gates = {}
for tag in a.gate_tags:
    path = ROOT / "npu/build" / ("chip-" + tag) / "result.json"
    j = read(path)
    assert j["passed"] and not j["changed_during_run"]
    for name, digest in j["sha256"].items():
        assert sha(name) == digest, name
    gates[tag] = j
f = out / "outputs/pad_moves.json"
pads = read(f) if f.exists() else None
report = {
    "scope": m["scope"],
    "run": str(r),
    "stages": stages,
    "checks": checks,
    "timing": timing,
    "placement": placement,
    "cts_strategy": read(r / "cts_strategy.json") if (r / "cts_strategy.json").exists() else None,
    "implemented_bbox": footprint,
    "pad_assignment": pads,
    "io_packing_audit": read(r / "io_audit.json") if (r / "io_audit.json").exists() else None,
    "export_integrity_audit": read(out / "reports/export_audit.json")
    if (out / "reports/export_audit.json").exists()
    else None,
    "gate_tests": gates,
    "artifacts_sha256": {
        str(f.relative_to(r)): sha(f) for f in (out / "outputs").rglob("*") if f.is_file()
    },
    "report_sha256": {
        str(f.relative_to(r)): sha(f) for f in (out / "reports").rglob("*") if f.is_file()
    },
    "limitations": [
        "TT single corner with captable RC, not multi-corner signoff.",
        "Native IO supply rails exist inside abutting library GDS cells and can be reported as no routing by Innovus; report this separately and audit IO geometry.",
        "No foundry DRC/LVS/ESD/EMIR signoff is implied.",
    ],
    "manifest_sha256": sha(r / "manifest.json"),
}
final_timing = {
    key: value
    for key, value in timing.items()
    if key.startswith(("reports/final_setup/", "reports/final_hold/"))
}
report["physical_closure"] = {
    "passed": any(key.startswith("reports/final_setup/") for key in final_timing)
    and any(key.startswith("reports/final_hold/") for key in final_timing)
    and all(row.get("wns_ns", -1) >= 0 for row in final_timing.values())
    and placement.get("13_final", {}).get("passed") is True
    and checks.get("13_final_drc", {}).get("violations") == 0
    and checks.get("13_final_signal", {}).get("reported_issues") == 0
    and checks.get("13_final_pg", {}).get("reported_issues") == 0,
    "scope": "Conservative check of available final reports, separate from stage command completion. Native IO rail warnings remain explicit; this is not foundry signoff.",
}
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
print(
    json.dumps(
        {
            "stages": {key: j["command_completed"] for key, j in stages.items()},
            "final_checks": checks,
            "footprint": footprint,
        },
        indent=2,
    )
)
