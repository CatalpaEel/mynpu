"""Verify the row CNN and independent engines, current tests and ASIC elaboration."""

import argparse, hashlib, json, re, subprocess, xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--run", required=True, type=Path)
p.add_argument("--baseline", required=True, type=Path)
a = p.parse_args()
run = a.run.resolve()
baseline = a.baseline.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
m = json.loads((run / "asic-input-check/source_manifest.json").read_text())
for f, h in m["source_sha256"].items():
    assert sha(ROOT.parent / f) == h, f
files = (ROOT / "build/sources.f").read_text().splitlines()
assert len(files) == 60 and not any(
    "softpe" in Path(f).name or Path(f).name.startswith(("noc_", "npu_noc_")) for f in files
)
core = (ROOT / "rtl/npu_core.sv").read_text()
for module, name in [("npu_matmul", "i_matmul"), ("npu_cnn", "i_cnn"), ("npu_vector", "i_vector")]:
    assert re.search(r"\b" + module + r"\s+" + name + r"\s*\(", core)
assert not re.search(r"npu_softpe|NOC_ENABLE|noc_csr_|noc_irq_", core)
units = {}
for f in [
    "npu_matmul.sv",
    "npu_vector.sv",
    "npu_mmio.sv",
    "xbar.sv",
    "npu_jtag_debug.sv",
    "npu_dma_channel.sv",
    "npu_dma_regs.sv",
]:
    assert sha(ROOT / "rtl" / f) == sha(baseline / "npu/rtl" / f), f
    units[f] = sha(ROOT / "rtl" / f)
assets = {}
for f in (ROOT / "mnist/artifacts").iterdir():
    if f.suffix in [".hex", ".bin"] and f.name.startswith(("input", "gold", "params")):
        assert sha(f) == sha(baseline / "npu/mnist/artifacts" / f.name), f
        assets[f.name] = sha(f)
ET.parse(ROOT.parent / "xc7a35t.xpr")
for el in ET.parse(ROOT.parent / "xc7a35t.xpr").iter("File"):
    assert not re.search(r"/(?:npu_softpe|softpe_|npu_control|noc_|npu_noc_)", el.attrib["Path"])
functional = {}
for suite in ["ops", "soc", "latency", "layers", "stream", "jtag", "xbar", "queues", "dma"]:
    tag = "cnn-row-final"
    macro = suite in ["ops", "soc", "latency", "layers", "stream", "jtag"]
    r = ROOT / "build" / ("vcs-" + tag + "-" + suite + ("-macro" if macro else "")) / "result.json"
    j = json.loads(r.read_text())
    assert j["passed"] and not j["changed_during_run"], suite
    for f, h in j["sha256"].items():
        assert sha(f) == h, (suite, f)
    compile_log = (r.parent / "compile.log").read_text()
    assert not re.search(r"Error-\[", compile_log), suite
    functional[suite] = {
        "passed": True,
        "result": str(r),
        "sha256": sha(r),
        "summaries": j["summaries"],
        "compile_warnings": re.findall(r"Warning-\[([^]]+)\]", compile_log),
    }
text = (ROOT / "build/vcs-cnn-row-final-latency-macro/run.log").read_text()
rows = re.findall(
    r"SINGLE sample=(\d+) useful_macs=(\d+) kernel_cycles=(\d+) elapsed_cycles=(\d+)", text
)
assert len(rows) == 10
inputs = re.findall(r"input_to_classification_cycles=(\d+)", text)
assert len(inputs) == 10
functional["latency"].update(
    samples=10, cycles=max(int(x[3]) for x in rows), inclusive_cycles=max(map(int, inputs))
)
assert (
    functional["latency"]["cycles"] == 27816 and functional["latency"]["inclusive_cycles"] == 28436
)
text = (ROOT / "build/vcs-cnn-row-final-stream-macro/run.log").read_text()
q = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", text)
assert q
functional["stream"].update(
    frames=int(q[1]), total_cycles=int(q[2]), cycles_per_frame=int(q[2]) / int(q[1])
)
text = (run / "asic-input-check/elab.log").read_text()
assert "CNN_ROW_ELAB_PASS" in text and "Normal exit." in text
check = (run / "asic-input-check/reports/elaborated_check.rpt").read_text()
structural = {}
for label in [
    "Unresolved References",
    "Empty Modules",
    "Undriven Port(s)",
    "Undriven Leaf Pin(s)",
    "Multidriven Port(s)",
    "Multidriven Leaf Pin(s)",
]:
    structural[label] = int(re.search(re.escape(label) + r"\s+(\d+)", check)[1])
    assert structural[label] == 0
subprocess.run(
    [
        "gcc",
        "-std=c11",
        "-Wall",
        "-Werror",
        "-fsyntax-only",
        "-x",
        "c",
        "-include",
        str(ROOT / "sw/npu.h"),
        "/dev/null",
    ],
    check=True,
)
old = ROOT.parent.parent / "eda-runs/20261101-operators-v1/validation.json"
out = {
    "branch": m["branch"],
    "scope": m["scope"],
    "source_sha256": m["source_sha256"],
    "source_count": 60,
    "independent_units": list(units),
    "baseline_unit_sha256": units,
    "baseline_asset_sha256": assets,
    "functional": functional,
    "architecture": {
        "matrix_queue_depth": 2,
        "vector_queue_depth": 2,
        "cnn_execution": "One output channel and row; CPU schedules output channels and rows",
        "matrix_cnn_memory_port": "Shared XBAR master1, mutually exclusive",
        "vector_memory_port": 2,
        "sram_banks": 2,
        "sram_bytes": 16384,
        "xbar_cache_words_per_bank": 16,
        "unified_pe_present": False,
        "network_present": False,
    },
    "asic_elaboration": {"passed": True, "tool": "Genus19.17", "checks": structural},
    "cnn_row_abi": {
        "register": 0x654,
        "value": 0x43524F31,
        "whole_layer_descriptor_compatible": False,
    },
    "performance_target": {
        "single_cycles_less_than": 20000,
        "met": functional["latency"]["cycles"] < 20000,
    },
    "synthesis_mapping_rerun": False,
    "post_route_verified": False,
    "current_area_mm2": None,
    "current_slack_ns": None,
    "historical_ppa_reference": str(old),
    "vivado_project": "Source references updated; XML parsed; Vivado implementation not run",
}
f = ROOT / "reports/independent_units_validation.json"
f.write_text(json.dumps(out, indent=2) + "\n")
(run / "validation.json").write_text(json.dumps(out, indent=2) + "\n")
print(
    "CNN ROW VALIDATION PASS",
    json.dumps(
        {
            "suites": len(functional),
            "cycles": functional["latency"]["cycles"],
            "inclusive": functional["latency"]["inclusive_cycles"],
            "stream": functional["stream"]["cycles_per_frame"],
            "output": str(f),
        }
    ),
)
