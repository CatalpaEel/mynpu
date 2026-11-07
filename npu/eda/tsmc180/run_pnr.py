"""Run restartable Innovus stages and retain command status separately from DRC/timing."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument(
    "--stages",
    nargs="+",
    choices=["init", "place", "pgfix", "cts", "route", "finish", "cleanup"],
    default=["init", "place", "pgfix", "cts", "route", "finish", "cleanup"],
)
a = p.parse_args()
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
m = json.loads((r / "manifest.json").read_text())
for group in ["input_sha256", "library_sha256"]:
    for path, digest in m[group].items():
        assert sha(path) == digest, path
for stage in a.stages:
    log = r / (stage + ".log")
    result = r / (stage + "_result.json")
    assert not log.exists() and not result.exists(), (
        "Use a fresh run or preserve prior logs before retrying"
    )
    snapshot = r / "scripts" / (stage + "_executed.tcl")
    shutil.copy2(r / "scripts/pnr.tcl", snapshot)
    cmd = ["innovus", "-no_gui", "-batch", "-files", str(snapshot)]
    hashes = {
        str(x): sha(x)
        for x in [r / "netlist.v", r / "constraints.sdc", *list((r / "scripts").glob("*.tcl"))]
    }
    with log.open("w") as f:
        rc = subprocess.run(
            cmd, cwd=r, env={**os.environ, "PNR_STAGE": stage}, stdout=f, stderr=subprocess.STDOUT
        ).returncode
    text = log.read_text()
    changed = [path for path, digest in hashes.items() if sha(path) != digest]
    completed = rc == 0 and "PNR_STAGE_PASS " + stage in text and not changed
    j = {
        "stage": stage,
        "command": cmd,
        "returncode": rc,
        "command_completed": completed,
        "changed_during_run": changed,
        "input_sha256": hashes,
        "log_sha256": sha(log),
        "scope": "Command completion is not DRC, connectivity or timing closure; inspect reports.",
    }
    result.write_text(json.dumps(j, indent=2) + "\n")
    print(stage, "COMPLETED" if completed else "FAILED", flush=True)
    if not completed:
        raise SystemExit(1)
