"""Attach frozen current-core PPA and software provenance to full native-PAD results."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--chip", type=Path, required=True)
p.add_argument("--gate-tags", nargs="*", default=[])
p.add_argument(
    "--out", type=Path, default=ROOT / "npu/reports/window_prefetch_fullchip_validation.json"
)
a = p.parse_args()
r = a.run.resolve()
chip = a.chip.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())
subprocess.run(
    [
        "python3.12",
        str(Path(__file__).with_name("collect_fullchip.py")),
        "--run",
        str(chip),
        "--out",
        str(a.out),
        "--gate-tags",
        *a.gate_tags,
    ],
    check=True,
)
j = read(a.out)


def synthesis(directory):
    qor = directory / "qor.rpt"
    text = qor.read_text()
    clocks = {
        name: dict(
            setup_wns_ns=float(wns) / 1000,
            setup_tns_ns=float(tns) / 1000,
            violating_paths=int(paths),
        )
        for name, wns, tns, paths in re.findall(
            r"^(sys_clk|jtag_clk)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", text, re.M
        )
    }
    area = float(re.search(r"Cell Area\s+([\d.]+)", text)[1]) / 1e6
    return dict(
        cell_area_mm2=area,
        clock_groups=clocks,
        qor_report=str(qor),
        qor_sha256=sha(qor),
        area_report=str(directory / "area.rpt"),
        area_sha256=sha(directory / "area.rpt"),
    )


core_manifest = read(r / "core/source_manifest.json")
for path, digest in core_manifest["source_sha256"].items():
    assert sha(ROOT / path) == digest, path
    frozen = r / "core/inputs" / path
    if not frozen.is_file() and path == "npu/rtl/npu_soc.sv":
        frozen = r / "source_provenance/npu_soc.sv"
    assert sha(frozen) == digest, path
derived = read(r / "derived_input_manifest.json")
for path, digest in derived.items():
    assert sha(r / path) == digest, path
j["derived_input_manifest_sha256"] = sha(r / "derived_input_manifest.json")
firmware = {}
for f in (r / "firmware").iterdir():
    if f.is_file():
        firmware[f.name] = sha(f)
for name, digest in firmware.items():
    image = chip / "inputs/images" / name
    if image.is_file():
        assert sha(image) == digest, name
functional = read(r / "functional_baseline.json")
assert len(functional["rtl"]) == 18 and functional["software"]["inference_cycles"] == 25388
# WNS printed as -0.000 can coexist with a real violation. Require counts
# and TNS too, rather than treating rounded slack as a timing pass.
final_rows = [
    v
    for k, v in j["timing"].items()
    if k.startswith(("reports/final_setup/", "reports/final_hold/"))
]
has_setup = any(k.startswith("reports/final_setup/") for k in j["timing"])
has_hold = any(k.startswith("reports/final_hold/") for k in j["timing"])
strict_timing = (
    has_setup
    and has_hold
    and bool(final_rows)
    and all(
        v.get("wns_ns", -1) >= 0 and v.get("tns_ns", -1) == 0 and v.get("violating_paths", -1) == 0
        for v in final_rows
    )
)
j["timing_closure_strict"] = strict_timing
j["physical_closure"]["passed"] = j["physical_closure"]["passed"] and strict_timing
signal = j["checks"].get("13_final_signal", {})
reported_nets = {
    line.split()[1].rstrip(":") for line in signal.get("summary", []) if line.startswith("Net ")
}
native_only = signal.get("reported_issues") == 2 and reported_nets == {"VDDPST", "VSSPST"}
core_signal_issues = 0 if native_only else signal.get("reported_issues")
j["native_io_rail_observations"] = dict(
    native_only=native_only,
    reported_issues=2 if native_only else None,
    geometry_audit=j.get("io_packing_audit"),
    scope="Original native IO rails retained; these tool observations are not waived as foundry connectivity signoff.",
)
j["core_physical_closure"] = dict(
    passed=strict_timing
    and j["placement"].get("13_final", {}).get("passed") is True
    and j["checks"].get("13_final_drc", {}).get("violations") == 0
    and j["checks"].get("13_final_pg", {}).get("reported_issues") == 0
    and core_signal_issues == 0,
    core_signal_reported_issues=core_signal_issues,
    scope="Core placement, interconnect geometry, signal/core PG connectivity and TT setup/hold. Native IO rail observations remain separately reported.",
)
j["backend_run"] = str(r)
j["synthesis"] = {
    "current_core": synthesis(r / "core/reports"),
    "mapped_shell_before_pad_insertion": synthesis(chip / "mynpu/chip_synth"),
    "scope": "Mapped Cell Area includes two SRAM macros; physical PADs and implementation additions are reported separately by the Innovus footprint.",
}
j["frozen_software"] = dict(
    sha256=firmware,
    functional_baseline=str(r / "functional_baseline.json"),
    functional_baseline_sha256=sha(r / "functional_baseline.json"),
    inference_cycles_rtl=25388,
    includes_external_dma_cycles_rtl=26009,
    note="Pin-level nine-pad chip loads via JTAG SBA. The RTL external-DMA timing is not the package ingress latency.",
)
core_gate = ROOT / "npu/build/gate-window-prefetch-backend-core/result.json"
if core_gate.is_file():
    gate = read(core_gate)
    assert gate["passed"] and not gate["changed_during_run"]
    for path, digest in gate["sha256"].items():
        assert sha(path) == digest, path
    j["mapped_core_functional"] = dict(
        result=str(core_gate), sha256=sha(core_gate), summaries=gate["summaries"]
    )
j["historical_comparison"] = dict(
    report="npu/reports/minimal_compute_validation.json",
    cell_area_mm2=2.666813940,
    note="2026-11-04 arithmetic/transfer snapshot before current RF sink and prefetch. It is not current physical evidence.",
)
a.out.write_text(json.dumps(j, indent=2) + "\n")
print(
    json.dumps(
        dict(
            synthesis=j["synthesis"],
            physical_closure=j["physical_closure"],
            placement=j["placement"],
        ),
        indent=2,
    )
)
