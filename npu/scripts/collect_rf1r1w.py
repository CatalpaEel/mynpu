"""Audit independent RF read/write ports, functional regressions and matched PPA."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from collect_layout_events import audit, ppa, timing

NPU = Path(__file__).resolve().parents[1]
ROOT = NPU.parent


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    args = parser.parse_args()
    run, experiment = args.run.resolve(), args.experiment.resolve()
    baseline_run = ROOT.parent / "eda-runs/20261108-area26-all4"
    old_manifest = json.loads((baseline_run / "source_manifest.json").read_text())
    new_manifest = json.loads((run / "source_manifest.json").read_text())
    changed = [
        p
        for p, h in old_manifest["source_sha256"].items()
        if new_manifest["source_sha256"].get(p) != h
    ]
    assert changed == ["npu/rtl/interconnect/npu_data_regfile.sv"], changed
    assert (run / "synth.sdc").read_bytes() == (baseline_run / "synth.sdc").read_bytes()
    assert (run / "report.sdc").read_bytes() == (baseline_run / "report.sdc").read_bytes()
    assert json.loads((run / "library_manifest.json").read_text()) == json.loads(
        (baseline_run / "library_manifest.json").read_text()
    )
    baseline = ppa(baseline_run)  # Read frozen run evidence; old comparison JSON is not kept in Git.
    for p, h in baseline["files_sha256"].items():
        assert sha(baseline_run / p) == h, p
    current = ppa(run, live=True)
    assert current["settings"] == baseline["settings"]
    dirs = [
        "vcs-rf1r1w-first-regfile",
        "vcs-rf1r1w-final-rfequivalence",
        "vcs-rf1r1w-large-rfequivalence",
        "vcs-rf1r1w-workloads-workloads-macro",
        "vcs-rf1r1w-events-layoutevents-macro",
        "vcs-rf1r1w-routes-unitroutes-macro",
        "vcs-rf1r1w-blocking-blocking-macro",
        "vcs-rf1r1w-xbar-xbarconcurrent",
        "vcs-rf1r1w-sink-rfsink",
        "vcs-rf1r1w-cpu-workloadcpu-macro",
        "vcs-rf1r1w-cpu-cnn-workloadcpu-macro",
        "vcs-rf1r1w-jtag-jtag-macro",
    ]
    tests = [audit(NPU / "build" / d) for d in dirs]
    gates = [
        audit(NPU / "build" / ("gate-rf1r1w-" + suite))
        for suite in ["latency", "units", "layout", "jtag"]
    ]
    for suite in ["latency", "units", "layout", "jtag"]:
        g = json.loads((NPU / "build" / ("gate-rf1r1w-" + suite) / "result.json").read_text())
        assert g["sha256"][str(run / "optimized.v")] == sha(run / "optimized.v")
    log = (NPU / "build/vcs-rf1r1w-blocking-blocking-macro/run.log").read_text()
    cycles = [int(x) for x in re.findall(r"BLOCKING PASS sample=\d+ cycles=(\d+)", log)]
    assert len(cycles) == 10 and cycles == [21008] * 10
    log = (NPU / "build/vcs-rf1r1w-final-rfequivalence/run.log").read_text()
    bandwidth = {
        int(old): dict(writes=int(w), reads=int(r), cycles=int(c))
        for old, w, r, c in re.findall(
            r"RF RW BANDWIDTH old=(\d+) writes=(\d+) reads=(\d+) cycles=(\d+)", log
        )
    }
    assert bandwidth[0]["cycles"] == 256 and bandwidth[1]["cycles"] == 512
    standalone = {}
    m = json.loads((experiment / "standalone_manifest.json").read_text())
    assert sha(Path(m["library"])) == m["library_sha256"]
    for name in ["old", "new"]:
        d = experiment / name
        for p, h in m[name]["frozen"].items():
            assert sha(Path(p)) == h, p
        assert sha(Path(m[name]["source"])) == m[name]["source_sha256"]
        assert "RF_STANDALONE_SYNTH_PASS" in (d / "launcher.log").read_text()
        assert "-period 18.0 " in (d / "synth.tcl").read_text()
        area = re.search(r"^npu_data_regfile\s+\d+\s+([\d.]+)", (d / "area.rpt").read_text(), re.M)
        assert area
        standalone[name] = dict(
            area_mm2=float(area[1]) / 1e6,
            area_report_sha256=sha(d / "area.rpt"),
            timing_report_sha256=sha(d / "timing.rpt"),
        )
    # The unchanged CPU clock gate contains one explicit enable latch. Compare
    # its exact cell/instance to the baseline; no data latch is permitted in RF.
    latch_pattern = r"^\s*((?:DLH|DLL|LHQ|LNQ)\w*BWP7T)\s+([^\s(]+)\s*\("
    netlist = (run / "optimized.v").read_text()
    latches = re.findall(latch_pattern, netlist, re.M)
    baseline_latches = re.findall(latch_pattern, (baseline_run / "optimized.v").read_text(), re.M)
    assert latches == baseline_latches
    assert all(
        name == "core_i_sleep_unit_i_core_clock_gate_i_enable_latched_reg" for _, name in latches
    )
    assert not re.findall(latch_pattern, (experiment / "new/mapped.v").read_text(), re.M)
    report = dict(
        passed=True,
        scope="RF 1R1W implementation; RTL and zero-delay mapped tests plus synthesis, no new PNR/signoff.",
        changed_rtl=changed,
        unchanged_cpu_clock_gate_latches=latches,
        rf_data_latches=0,
        tests=tests,
        gate_tests=gates,
        mnist_cycles=cycles,
        same_bank_bandwidth=bandwidth,
        standalone_rf=standalone,
        ppa=current,
        baseline_ppa=baseline,
        area_delta_mm2=current["total_area_mm2"] - baseline["total_area_mm2"],
        area_delta_percent=(current["total_area_mm2"] / baseline["total_area_mm2"] - 1) * 100,
        semantics="One physical read and one independent write per bank; same-edge read gets old data; byte enables preserved; ordinary access limited to one read+one write per logical half.",
        source_sha256={
            str(NPU / "rtl/interconnect/npu_data_regfile.sv"): sha(
                NPU / "rtl/interconnect/npu_data_regfile.sv"
            )
        },
        limitations=[
            "No extra read ports; same-bank different-address reads still arbitrate.",
            "Current MNIST and general workload suite have unchanged total cycles.",
            "1950um PNR and Lab5 reports belong to the preceding 1RW RTL.",
            "Whole-design mapping changes may affect other modules; isolated RF comparison is separate.",
            "Standalone attempts marked invalid_units are discarded and are not used.",
        ],
    )
    out = NPU / "reports/rf1r1w-validation.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            {
                k: report[k]
                for k in ["passed", "area_delta_mm2", "area_delta_percent", "standalone_rf"]
            },
            indent=2,
        )
    )
    print(out)


if __name__ == "__main__":
    main()
