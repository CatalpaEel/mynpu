"""Archive convolution-only CNN evidence, keeping PPA and cycle regressions explicit."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--baseline", type=Path, required=True)
p.add_argument("--tag", default="cnn-conv-only-final")
p.add_argument("--boundary-tag", default="cnn-conv-only-boundary")
p.add_argument("--gate-tags", nargs="*", default=[])
p.add_argument("--out", type=Path, default=ROOT / "npu/reports/cnn_conv_only_validation.json")
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())
m = read(r / "source_manifest.json")
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (r / "launcher.log").read_text()
for name, digest in m["source_sha256"].items():
    assert sha(ROOT / name) == digest, name
for name, digest in read(r / "library_manifest.json").items():
    assert sha(name) == digest, name


def ppa(run):
    area = (run / "reports/area.rpt").read_text()
    qor = (run / "reports/qor.rpt").read_text()
    cells = float(re.search(r"Cell Area\s+([\d.]+)", qor)[1]) / 1e6
    match = re.search(r"^sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s*$", qor, re.M)
    rows = {
        line.split()[0]: float(line.split()[-3]) / 1e6
        for line in area.splitlines()
        if line.startswith("  i_")
    }
    mac = float(re.search(r"^    i_mac\s+\S+\s+\d+\s+([\d.]+)", area, re.M)[1]) / 1e6
    return dict(
        cell_area_mm2=cells,
        cnn_engine_mm2=rows["i_core_i_cnn_i_engine"],
        cnn_control_mm2=rows["i_core_i_cnn_i_control"],
        cnn_mac_mm2=mac,
        cnn_total_mm2=rows["i_core_i_cnn_i_engine"] + rows["i_core_i_cnn_i_control"],
        sys_setup_slack_ns=float(match[1]) / 1000,
        sys_tns_ns=float(match[2]) / 1000,
        hierarchy_mm2=rows,
        area_report_sha256=sha(run / "reports/area.rpt"),
        qor_report_sha256=sha(run / "reports/qor.rpt"),
    )


def archive_result(source, category, label):
    j = read(source)
    assert j["passed"] and not j["changed_during_run"], source
    snapshots = {}
    for name, digest in j["sha256"].items():
        f = Path(name)
        assert sha(f) == digest, name
        # Keep source/assets and local generated gate inputs; vendor libraries stay external.
        if f.is_relative_to(ROOT) or f.is_relative_to(r):
            dst = r / "functional_inputs" / digest / f.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copy2(f, dst)
            assert sha(dst) == digest
            snapshots[name] = str(dst)
    dst = r / category / label
    dst.mkdir(parents=True, exist_ok=True)
    for name in ["result.json", "run.log", "command.json"]:
        if (source.parent / name).exists():
            shutil.copy2(source.parent / name, dst / name)
    return dict(
        passed=True,
        result=str(dst / "result.json"),
        result_sha256=sha(dst / "result.json"),
        run_log_sha256=sha(dst / "run.log"),
        summaries=j.get("summaries", []),
        snapshots=snapshots,
    )


suites = [
    "latency",
    "layers",
    "stream",
    "soc",
    "jtag",
    "ops",
    "burst",
    "xbar",
    "xbarconcurrent",
    "queues",
    "cnnqueues",
    "dma",
    "enginefaults",
    "regfile",
    "vectorprogram",
]
rtl = {}
for suite in suites:
    tag = a.boundary_tag if suite in ["latency", "layers"] else a.tag
    rtl[suite] = archive_result(
        ROOT / "npu/build" / f"vcs-{tag}-{suite}" / "result.json", "rtl_tests", suite
    )
gates = {
    tag: archive_result(ROOT / "npu/build" / f"gate-{tag}" / "result.json", "gate_tests", tag)
    for tag in a.gate_tags
}
auxiliary = {}
for name in ["firmware_rebuild_check.json", "parameter_preservation_check.json"]:
    f = r.parent / name
    check = read(f)
    assert check["passed"], f
    auxiliary[name] = {"path": str(f), "sha256": sha(f), "result": check}
log = Path(rtl["latency"]["result"]).with_name("run.log").read_text()
cycles = [int(v) for v in re.findall(r"SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", log)]
assert len(cycles) == 10 and len(set(cycles)) == 1, cycles
model = read(ROOT / "npu/mnist/artifacts/model.json")
assert model["fc_execution"].startswith("signed packed GEMM")
firmware = r / "firmware"
firmware.mkdir(exist_ok=True)
for f in (ROOT / "npu/mnist/artifacts").iterdir():
    if f.suffix in [".hex", ".bin", ".svh", ".json", ".S"]:
        shutil.copy2(f, firmware / f.name)
for name in ["firmware.py", "stream_firmware.py"]:
    shutil.copy2(ROOT / "npu/mnist" / name, firmware / name)
current = ppa(r)
baseline = ppa(a.baseline.resolve())
baseline_manifest = read(a.baseline / "source_manifest.json")
assert read(r / "library_manifest.json") == read(a.baseline / "library_manifest.json")
changed_rtl = [
    name
    for name, digest in m["source_sha256"].items()
    if baseline_manifest["source_sha256"].get(name) != digest
]
assert changed_rtl and all(name.startswith("npu/rtl/npu_cnn_") for name in changed_rtl)
assert "descriptor_bits=81" in Path(rtl["cnnqueues"]["result"]).with_name("run.log").read_text()
for key in [
    "effort",
    "rf_bank_words",
    "cnn_queue_depth",
    "matrix_queue_depth",
    "vector_queue_depth",
    "synth_period_ns",
    "report_period_ns",
]:
    assert m[key] == baseline_manifest[key], key
report = dict(
    scope="CNN convolution only, FC on existing GEMM plus generic VPG1; TSMC180 TT mapped synthesis and no-SDF functional simulations. No new placement/routing.",
    run=str(r),
    configuration=m,
    changed_rtl_sources=changed_rtl,
    ppa=current,
    baseline=dict(run=str(a.baseline.resolve()), ppa=baseline, inference_cycles=19986),
    delta=dict(
        cell_area_mm2=current["cell_area_mm2"] - baseline["cell_area_mm2"],
        cnn_area_mm2=current["cnn_total_mm2"] - baseline["cnn_total_mm2"],
        inference_cycles=cycles[0] - 19986,
    ),
    software=dict(
        inference_cycles=cycles[0],
        cycle_target_met=cycles[0] < 20000,
        cnn_row_tasks=212,
        matrix_fc_tasks=90,
        cnn_macs=39330,
        matrix_fc_macs=1440,
        cnn_descriptor_bits=81,
        cnn_abi="CRW2 0x43525732",
        parameter_bytes=model["parameter_bytes"],
        fc_raw_base=model["fc_raw_base"],
    ),
    rtl=rtl,
    gates=gates,
    auxiliary_checks=auxiliary,
    firmware_sha256={f.name: sha(f) for f in firmware.iterdir() if f.is_file()},
    limitations=[
        "FC is functionally migrated but exceeds the prior 20k cycle target on the existing scalar K<=16 GEMM engine.",
        "Mapped area excludes PAD and implementation buffers; no physical area or timing closure is implied.",
        "Historical reports remain snapshots of their own RTL/firmware, not current results.",
    ],
)
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
print(
    json.dumps(
        dict(
            ppa=current,
            delta=report["delta"],
            software=report["software"],
            rtl_suites=len(rtl),
            gate_suites=len(gates),
        ),
        indent=2,
    )
)
