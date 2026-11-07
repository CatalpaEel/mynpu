"""Validate frozen RF capacity experiments and summarize measured synthesis results."""

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--selected", required=True)
p.add_argument("--gate-tags", nargs="*", default=[])
a = p.parse_args()
run = a.run.resolve()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


variants = {}
for name in ["rf256", "rf128", "rf64", "rf32", "rf64-q8"]:
    r = run / name
    m = read(r / "source_manifest.json")
    for path, digest in m["source_sha256"].items():
        assert sha(ROOT / path) == digest, path
    lib = read(r / "library_manifest.json")

    # Library manifest shapes are retained in the report; all file digest entries are checked.
    def check_library(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if (
                    isinstance(value, str)
                    and re.fullmatch("[0-9a-f]{64}", value)
                    and Path(key).is_file()
                ):
                    assert sha(key) == value, key
                else:
                    check_library(value)
        elif isinstance(node, list):
            for value in node:
                check_library(value)

    check_library(lib)
    f = read(r / "functional_manifest.json")
    records = {}
    for suite, record in f["regressions"].items():
        path = Path(record["result"])
        assert sha(path) == record["sha256"]
        assert sha(path.parent / "run.log") == record["run_log_sha256"]
        j = read(path)
        assert j["passed"] and not j["changed_during_run"]
        assert j["rf_bank_words"] == m["rf_bank_words"]
        for key in ["matrix_queue_depth", "vector_queue_depth", "cnn_queue_depth"]:
            assert j[key] == m[key]
        for source, digest in j["sha256"].items():
            frozen = f["snapshots"].get(source, source)
            assert sha(frozen) == digest, frozen
        records[suite] = {"passed": True, "summaries": j.get("summaries", []), **record}
    assert len(records) == 15
    for image, digest in f["image_sha256"].items():
        assert sha(r / "images" / image) == digest
    assert "DUAL_BANK_ASIC_SYNTH_PASS" in (r / "launcher.log").read_text()
    structure = (r / "reports/check_design.rpt").read_text()
    for label in [
        "Unresolved References",
        "Empty Modules",
        "Undriven Leaf Pin(s)",
        "Multidriven Leaf Pin(s)",
        "Multidriven Port(s)",
    ]:
        match = re.search(r"^" + re.escape(label) + r"\s+(\d+)", structure, re.M)
        assert match and int(match[1]) == 0, (name, label)
    qor = (r / "reports/qor.rpt").read_text()
    area = float(re.search(r"^Cell Area\s+([\d.]+)", qor, re.M)[1]) / 1e6
    slack = {}
    for clock in ["sys_clk", "jtag_clk"]:
        match = re.search(r"^" + clock + r"\s+([\d.-]+)\s+([\d.-]+)\s+(\d+)", qor, re.M)
        assert match and float(match[2]) == 0 and int(match[3]) == 0
        slack[clock] = float(match[1]) / 1000
    area_text = (r / "reports/area.rpt").read_text()
    rf = re.search(r"i_regfile\s+\S+\s+\d+\s+([\d.]+)", area_text)
    latency_log = (r / "functional/latency/run.log").read_text()
    stream_log = (r / "functional/stream/run.log").read_text()
    inference = [
        int(x) for x in re.findall(r"SINGLE sample=\d+ .*?elapsed_cycles=(\d+)", latency_log)
    ]
    inclusive = [int(x) for x in re.findall(r"input_to_classification_cycles=(\d+)", latency_log)]
    stream = re.search(r"STREAM PASS frames=(\d+) .*?elapsed_cycles=(\d+)", stream_log)
    assert len(inference) == 10 and len(inclusive) == 10 and stream
    variants[name] = {
        "rf_bytes": m["rf_bank_words"] * 8,
        "inference_cycles": inference,
        "input_to_classification_cycles": inclusive,
        "stream_cycles_per_frame": int(stream[2]) / int(stream[1]),
        "matrix_queue_depth": m["matrix_queue_depth"],
        "vector_queue_depth": m["vector_queue_depth"],
        "cnn_queue_depth": m["cnn_queue_depth"],
        "cell_area_mm2": area,
        "regfile_cell_area_mm2": float(rf[1]) / 1e6,
        "setup_slack_ns": slack,
        "fits_3mm2_cell_budget": area <= 3,
        "functional": records,
        "source_manifest_sha256": sha(r / "source_manifest.json"),
        "library_manifest_sha256": sha(r / "library_manifest.json"),
        "report_sha256": {f.name: sha(f) for f in (r / "reports").glob("*.rpt")},
        "image_sha256": f["image_sha256"],
    }
selected = variants[a.selected]
assert selected["fits_3mm2_cell_budget"] and min(selected["setup_slack_ns"].values()) >= 0
config = read(ROOT / "npu/build_config.json")
assert config["rf_bank_words"] * 8 == selected["rf_bytes"]
for key in ["matrix_queue_depth", "vector_queue_depth", "cnn_queue_depth"]:
    assert config[key] == selected[key]
for name, digest in selected["image_sha256"].items():
    assert sha(ROOT / "npu/mnist/artifacts" / name) == digest, name
mapped = {}
for tag in a.gate_tags:
    path = ROOT / "npu/build" / ("gate-" + tag) / "result.json"
    j = read(path)
    assert j["passed"] and not j["changed_during_run"], tag
    assert j["sha256"][str(run / a.selected / "optimized.v")] == sha(
        run / a.selected / "optimized.v"
    )
    for path, digest in j["sha256"].items():
        assert sha(path) == digest, path
    mapped[tag] = j
baseline_assets = read(run / "before/rtl_tidy_validation.json")[
    "firmware_and_hex_assets_unchanged_sha256"
]
unchanged_model_assets = {
    key: digest
    for key, digest in baseline_assets.items()
    if key.startswith(("gold", "input")) or key in {"model.hex", "weights.hex", "params.hex"}
}
for name, digest in unchanged_model_assets.items():
    assert sha(ROOT / "npu/mnist/artifacts" / name) == digest, name
report = {
    "selected": a.selected,
    "build_config": config,
    "cnn_abi": "CRW1 raw INT32; postprocessing belongs to vector",
    "target_cell_area_mm2": 3,
    "planned_core_mm": [2, 2],
    "technology": "TSMC180 TT; Genus19.17 low effort; 16ns optimize, 20ns report",
    "scope": "Includes CPU, DM/JTAG, DMA, two real 8KB SRAM macros, compute units and RF. No PAD or PnR. Gate simulation has no SDF.",
    "variants": variants,
    "mapped": mapped,
    "unchanged_model_assets_sha256": unchanged_model_assets,
}
text = json.dumps(report, indent=2) + "\n"
(ROOT / "npu/reports/regfile_vector_validation.json").write_text(text)
(run / "validation.json").write_text(text)
print(
    json.dumps(
        {
            k: {key: v[key] for key in ["rf_bytes", "cell_area_mm2", "setup_slack_ns"]}
            for k, v in variants.items()
        },
        indent=2,
    )
)
