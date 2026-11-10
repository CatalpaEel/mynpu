"""Collect actual Lab 5 results, separating tool completion from acceptance."""

import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read(path):
    return Path(path).read_text(errors="replace")


def checks(path, erc=False):
    text = read(path)
    rows = [
        dict(rule=name, hierarchical=int(h), expanded=int(f))
        for name, h, f in re.findall(
            r"^RULECHECK (\S+)\s+\.+ TOTAL Result Count = (\d+)\s+\((\d+)\)", text, re.M
        )
    ]
    kind = "ERC" if erc else "DRC"
    count = re.search(rf"TOTAL {kind} RuleChecks Executed:\s+(\d+)", text)
    totals = re.search(rf"TOTAL {kind} (?:RuleCheck )?Results Generated:\s+(\d+)\s+\((\d+)\)", text)
    assert count and totals and len(rows) == int(count[1]), path
    return dict(
        report=str(path),
        sha256=sha(path),
        checks=int(count[1]),
        hierarchical_results=int(totals[1]),
        expanded_results=int(totals[2]),
        nonzero=[row for row in rows if row["hierarchical"]],
    )


def lvs(path):
    text = read(path)
    after = text.split("NUMBERS OF OBJECTS AFTER TRANSFORMATION", 1)[1]
    counts = {}
    for label in ["Ports", "Nets", "Total Inst"]:
        m = re.search(r"^\s*" + label + r":\s+(\d+)\s+(\d+)", after, re.M)
        assert m, label
        counts[label] = dict(layout=int(m[1]), source=int(m[2]))
    return dict(
        report=str(path),
        sha256=sha(path),
        correct=bool(
            re.search(r"^\s*CORRECT\s+mynpu_asic_top_postDummy\s+mynpu_asic_top\s*$", text, re.M)
        ),
        full_property_checks=len(re.findall(r"^\s*TRACE PROPERTY\s+", text, re.M)),
        split_gates=bool(re.search(r"LVS REDUCE SPLIT GATES\s+YES", text)),
        resistor_tolerance=re.findall(r"TRACE PROPERTY\s+r\(pr\)\s+r r ([\d.]+)", text),
        transformed_counts=counts,
        warnings=sorted(set(re.findall(r"^\s*Warning:.*$", text, re.M))),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    run = args.run.resolve()
    manifest = json.loads(read(run / "manifest.json"))
    baseline = Path(manifest["source_pnr_run"])
    assert sha(baseline / "manifest.json") == manifest["source_pnr_manifest_sha256"]
    for name, digest in manifest["input_sha256"].items():
        assert sha(name) == digest and sha(run / "inputs" / Path(name).name) == digest, name
    pm = json.loads(read(baseline / "manifest.json"))
    for name, digest in pm["core_source_manifest"]["source_sha256"].items():
        assert sha(ROOT / name) == digest, name
    for name, digest in manifest["reference_sha256"].items():
        assert sha(run / "reference" / name) == digest, name
    gds = run / "outputs/mynpu_asic_top_postDummy.gds"
    cdl = run / "cdl/mynpu_asic_top.cdl"
    gds_hash = sha(gds)
    tolerance = json.loads(read(run / "outputs/lvs_tolerance_change.json"))
    assert tolerance["final_gds_sha256"] == gds_hash
    for name in ["post.drc", "post.lvs", "post.ant", "post.wb"]:
        text = read(run / "rules" / name)
        assert (
            f'LAYOUT PATH "{gds}"' in text and 'LAYOUT PRIMARY "mynpu_asic_top_postDummy"' in text
        )
        assert not re.search(r"^\s*LVS BOX\s+.*RA1SHD", text, re.M)
    includes = re.findall(r'^\.INCLUDE "([^"]+)"', read(cdl), re.M)
    assert len(includes) == 3 and any(name.endswith("RA1SHD_2048x32M8.cdl") for name in includes)
    drc = checks(run / "drc_post/summary.rpt")
    drc["course_four_class_exclusions"] = ["DRM", "ESD", "MOM", "LUP"]
    drc["remaining_after_course_exclusions"] = [
        row for row in drc["nonzero"] if not row["rule"].startswith(("DRM", "ESD", "MOM", "LUP"))
    ]
    drc["course_passed"] = not drc["remaining_after_course_exclusions"]
    antenna, wb = checks(run / "antenna/summary.rpt"), checks(run / "wb/summary.rpt")
    strict, teaching = lvs(run / "lvs_strict/report.rpt"), lvs(run / "lvs/report.rpt")
    assert teaching["full_property_checks"] == 605 and teaching["resistor_tolerance"] == ["3.48"]
    assert teaching["split_gates"] and all(
        v["layout"] == v["source"] for v in teaching["transformed_counts"].values()
    )
    erc = checks(run / "lvs/erc.summary", erc=True)
    stages = {
        "v2lvs": ("v2lvs.log", "Design Conversion completed"),
        "virtuoso_exact_import": ("streamin_exact.log", "Translation completed. '0' error"),
        "metal_fill": ("dummy_metal.log", "CALIBRE::DRC-H COMPLETED"),
        "od_po_fill": ("dummy_od_po.log", "CALIBRE::DRC-H COMPLETED"),
        "merge": ("merge.log", "Merge completed successfully"),
        "virtuoso_final_import": ("final_streamin.log", "Translation completed. '0' error"),
        "post_drc": ("drc_post.log", "CALIBRE::DRC-H COMPLETED"),
        "lvs_erc": ("lvs_teaching.log", "CALIBRE::LVS/xRC COMPLETED"),
        "antenna": ("antenna.log", "CALIBRE::DRC-H COMPLETED"),
        "wire_bond": ("wb.log", "CALIBRE::DRC-H COMPLETED"),
    }
    stage_results = {}
    for name, (log, marker) in stages.items():
        text = read(run / "logs" / log)
        stage_results[name] = dict(
            completed=marker in text, log=str(run / "logs" / log), sha256=sha(run / "logs" / log)
        )
    report = dict(
        run=str(run),
        guide=manifest["guide"],
        flow_commands_completed=all(j["completed"] for j in stage_results.values()),
        course_acceptance_passed=False,
        foundry_signoff_passed=False,
        stages=stage_results,
        drc=drc,
        lvs_strict=strict,
        lvs_lab5_tolerance=teaching,
        erc=erc,
        antenna=antenna,
        wire_bond=wb,
        dimensions=dict(
            original_die_um=[2000, 2000],
            with_sealring_um=[2030, 2030],
            course_die_limit_um=[1950, 1950],
            course_sealring_limit_um=[1980, 1980],
            course_passed=False,
        ),
        m1_localization=json.loads(read(run / "outputs/m1_localization.json")),
        precision_adjustments=json.loads(read(run / "outputs/precision_adjustments.json")),
        source_libraries_sha256={name: sha(name) for name in includes},
        final_input_sha256={str(gds): gds_hash, str(cdl): sha(cdl)},
        script_sha256={
            str(p.relative_to(run)): sha(p) for p in (run / "scripts").iterdir() if p.is_file()
        },
        report_and_rule_sha256={
            str(p.relative_to(run)): sha(p)
            for directory in ["rules", "logs", "drc_post", "antenna", "wb", "lvs", "lvs_strict"]
            for p in (run / directory).iterdir()
            if p.is_file()
        },
        limitations=[
            "M1.S.1 spacing violations remain and are not in the four course-excluded classes.",
            "Original die and sealring envelope exceed Lab5 size limits.",
            "ERC has unresolved IO/outer-substrate findings requiring review; not ERC Clean.",
            "LVS CORRECT uses the documented teaching PR tolerance, not strict original resistor properties.",
            "No postDummy parasitic extraction/STA or IR/EM/package signoff performed.",
        ],
    )
    out = ROOT / "npu/reports/lab5_all4_validation.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    (run / "outputs/final_inputs.sha256").write_text(f"{gds_hash}  {gds}\n{sha(cdl)}  {cdl}\n")
    print(
        json.dumps(
            {
                k: report[k]
                for k in [
                    "flow_commands_completed",
                    "course_acceptance_passed",
                    "foundry_signoff_passed",
                ]
            },
            indent=2,
        )
    )
    print(out)


if __name__ == "__main__":
    main()
