"""Archive arithmetic-only unit regressions and observational MNIST cycle profiles."""

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, default=ROOT.parent / "eda-runs/20261105-pure-compute")
p.add_argument("--tag", default="pure-compute-final")
p.add_argument("--out", type=Path, default=ROOT / "npu/reports/pure_compute_validation.json")
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
read = lambda f: json.loads(Path(f).read_text())


def archive(source, category, label, baseline=False):
    j = read(source)
    assert j["passed"] and not j["changed_during_run"], source
    snapshots = {}
    for name, digest in j["sha256"].items():
        original = Path(name)
        candidates = [original]
        if baseline and original.is_relative_to(ROOT / "npu/rtl"):
            candidates.insert(0, r / "before/rtl" / original.name)
        if baseline and original.name in ["mnist_profile.svh", "tb_mnist_latency.sv"]:
            candidates.insert(0, r / "baseline" / original.name)
        f = next((q for q in candidates if q.is_file() and sha(q) == digest), None)
        assert f is not None, name
        if original.is_relative_to(ROOT):
            dst = r / "functional_inputs" / digest / original.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copy2(f, dst)
            assert sha(dst) == digest
            snapshots[name] = str(dst)
    dst = r / category / label
    dst.mkdir(parents=True, exist_ok=True)
    for name in ["result.json", "run.log", "command.json"]:
        if (
            source.parent.joinpath(name).exists()
            and source.parent.joinpath(name).resolve() != dst.joinpath(name).resolve()
        ):
            shutil.copy2(source.parent / name, dst / name)
    return dict(
        passed=True,
        result=str(dst / "result.json"),
        result_sha256=sha(dst / "result.json"),
        run_log_sha256=sha(dst / "run.log"),
        summaries=j["summaries"],
        snapshots=snapshots,
    )


def profiles(path):
    rows = [
        dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", line))
        for line in Path(path).read_text().splitlines()
        if line.startswith("STAGE_PROFILE")
    ]
    assert len(rows) == 70
    for sample in range(10):
        group = rows[sample * 7 : sample * 7 + 7]
        assert [x["stage"] for x in group] == list(range(7))
        assert all(x["sample"] == sample for x in group)
        assert sum(x["cycles"] for x in group) == 29206
        for row in group:
            assert row["cnn_busy"] == sum(
                row[k]
                for k in [
                    "cnn_issue",
                    "cnn_weight",
                    "cnn_output",
                    "cnn_seed",
                    "cnn_input",
                    "cnn_other",
                ]
            )
    return rows


suites = [
    "purecompute",
    "cnncompute",
    "regfile",
    "cnnqueues",
    "ops",
    "jtag",
    "soc",
    "xbar",
    "xbarconcurrent",
    "dma",
    "queues",
    "burst",
    "enginefaults",
    "vectorprogram",
    "latency",
    "layers",
    "stream",
]
rtl = {
    s: archive(ROOT / "npu/build" / f"vcs-{a.tag}-{s}" / "result.json", "rtl_tests", s)
    for s in suites
}
macro = archive(
    ROOT / "npu/build" / f"vcs-{a.tag}-latency-macro" / "result.json", "rtl_tests", "latency-macro"
)
baseline = archive(r / "baseline/result.json", "baseline", "profile", True)
old = profiles(Path(baseline["result"]).with_name("run.log"))
new = profiles(Path(rtl["latency"]["result"]).with_name("run.log"))
for before, after in zip(old, new):
    assert all(after[k] == v for k, v in before.items()), (before, after)
macro_profile = profiles(Path(macro["result"]).with_name("run.log"))
assert macro_profile == new
rows = new[:7]
totals = {k: sum(row[k] for row in rows) for k in rows[0] if k not in ["sample", "stage"]}
assert totals["cnn_seed_read_words"] == totals["cnn_write_words"] == 3472
assert totals["cnn_activation_gather_words"] == 1344
assert totals["cnn_input"] == 10967 and totals["matrix_busy"] == 6100
assert (
    totals["cnn_busy"]
    + totals["matrix_busy"]
    + totals["vector_busy"]
    - totals["both_cnn_vector"]
    - totals["both_matrix_vector"]
    + totals["no_engine"]
    == 29206
)

# The compiler/image/weights/golden did not change in this boundary refactor.
stream_log = Path(rtl["stream"]["result"]).with_name("run.log").read_text()
stream_match = re.search(r"STREAM PASS frames=(\d+).*?elapsed_cycles=(\d+)", stream_log)
assert stream_match and int(stream_match[1]) == 20 and int(stream_match[2]) == 590811
previous = read(ROOT / "npu/reports/minimal_compute_validation.json")
firmware_unchanged = {}
for name, digest in previous["firmware_sha256"].items():
    f = ROOT / "npu/mnist/artifacts" / name
    if not f.is_file():
        f = ROOT / "npu/mnist" / name
    assert sha(f) == digest, name
    firmware_unchanged[name] = digest

units = {}
for module in ["npu_cnn", "npu_cnn_mac", "npu_matmul", "npu_vector"]:
    f = ROOT / "npu/rtl" / f"{module}.sv"
    text = f.read_text()
    header = text[text.index("module ") : text.index(");")]
    # Public pure-compute ports carry arithmetic only; no legacy descriptor ABI.
    assert not re.search(
        r"\b(?:start_i|addr_o|req_o|gnt_i|program_i|len_i|m_i|n_i|k_i)\b", header
    ), module
    units[module] = dict(source=str(f), sha256=sha(f))
report = dict(
    scope="Separate CNN/DOT9, matrix MAC and vector ALU arithmetic from operand/task control; unchanged software and exact inference schedule. RTL and SRAM-macro functional regressions only; no new synthesis/PnR claim.",
    run=str(r),
    configuration=read(ROOT / "npu/build_config.json"),
    units=units,
    task_control=["npu_stream", "npu_matrix_stream", "npu_vector_issue", "npu_mmio"],
    rtl=rtl,
    sram_macro_latency=macro,
    baseline=baseline,
    software=dict(
        inference_cycles=29206,
        input_dma_cycles=621,
        input_dma_inclusive_cycles=29827,
        baseline_inference_cycles=29206,
        cycle_delta=0,
        cycle_target_met=False,
        stream_frames=20,
        stream_elapsed_cycles=590811,
        stream_average_cycles=590811 / 20,
        firmware_changed=False,
        shared_profile_counters_identical=True,
    ),
    stage_names=[
        "conv1 plus boot/setup",
        "conv2",
        "conv3",
        "conv4",
        "conv5",
        "FC plus recenter/setup/post",
        "argmax/finalization",
    ],
    stage_profiles=rows,
    totals=totals,
    all_profiles=new,
    critical_findings=[
        "CNN activation-window starvation is 10967 exclusive busy cycles; weights 1889, seed 952, output 817, issue 5256, setup/drain 1165.",
        "FC stage is 7029 cycles; matrix busy 6100 includes 1440 A requests + 1440 A replies + 1440 B requests + 1440 B replies, 160 accumulation read cycles and 180 store cycles.",
        "Vector busy overlaps CNN for 20980 cycles and waits for input for 17439 cycles; busy totals must not be added as serial latency.",
        "Shared-RF partial traffic is 3472 writes plus 3472 gather reads. RF bank conflict is only 32 cycles, not the dominant measured bottleneck.",
    ],
    unchanged_firmware_sha256=firmware_unchanged,
    physical_result=dict(
        measured_for_current_revision=False,
        historical_report="npu/reports/minimal_compute_validation.json",
    ),
    limitations=[
        "External feeders/issuer still have address loops, memory response FSMs and vector PC/register state; arithmetic-only does not mean the full subsystem is stateless.",
        "Exclusive CNN wait bins use priority issue, weight, output, seed, input, other. Multiple physical waits may overlap; these are not independent speedup estimates.",
        "First conv stage includes boot/setup; FC stage includes CPU recenter, queues and vector postprocessing; timing boundaries are CPU progress stores, not host polling.",
        "No new mapped area, routed timing or PAD result is claimed.",
    ],
)
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(report, indent=2) + "\n")
shutil.copy2(__file__, r / "collect_pure_compute.py")
print(
    json.dumps(
        dict(rtl_suites=len(rtl), macro=True, software=report["software"], totals=totals), indent=2
    )
)
