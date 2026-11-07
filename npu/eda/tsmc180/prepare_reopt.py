"""Freeze a mapped-DB area reoptimization at an explicit clock target."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--seed", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--period", type=float, required=True)
p.add_argument("--register-aware", action="store_true")
a = p.parse_args()
seed = a.seed.resolve()
assert "DUAL_BANK_ASIC_SYNTH_PASS" in (seed / "launcher.log").read_text()
m = json.loads((seed / "source_manifest.json").read_text())
for name, sha in m["source_sha256"].items():
    assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == sha, name
subprocess.run(
    [
        sys.executable,
        str(Path(__file__).with_name("prepare_run.py")),
        "--out",
        str(a.out),
        "--effort",
        "high",
        "--clock-gating",
        "--synth-period",
        str(a.period),
    ],
    check=True,
)
r = a.out.resolve()
fresh = json.loads((r / "source_manifest.json").read_text())
assert m["source_sha256"] == fresh["source_sha256"]
for key in ["rf_bank_words", "matrix_queue_depth", "vector_queue_depth", "cnn_queue_depth"]:
    assert m[key] == fresh[key], key
assert json.loads((r / "library_manifest.json").read_text()) == json.loads(
    (seed / "library_manifest.json").read_text()
)
original = (r / "synth.tcl").read_text()
(r / "full_synth_reproduction.tcl").write_text(original)
db = seed / "optimized.db"
script = (
    f"set_db max_cpus_per_server 4\nread_db {db}\nset_db syn_opt_effort high\nread_sdc {r / 'synth.sdc'}\n"
    + original[original.index("syn_opt\n") :]
)
if a.register_aware:
    script = script.replace(
        "syn_opt\n",
        "set_db lp_insert_clock_gating_incremental true\nset_db lp_clock_gating_register_aware true\nsyn_opt\n",
        1,
    )
(r / "synth.tcl").write_text(script)
fresh.update(
    seed_db=str(db),
    seed_db_sha256=hashlib.sha256(db.read_bytes()).hexdigest(),
    flow="High-effort mapped DB reoptimization at explicit period",
    register_aware=a.register_aware,
)
(r / "source_manifest.json").write_text(json.dumps(fresh, indent=2) + "\n")
print(r)
