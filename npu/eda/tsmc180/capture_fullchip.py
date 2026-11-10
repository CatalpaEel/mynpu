"""Capture an actual Innovus checkpoint and record its image/database provenance."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--display", default=os.environ.get("DISPLAY", ""))
    args = parser.parse_args()
    run, out = args.run.resolve(), args.out.resolve()
    assert args.display, "A working DISPLAY or --display is required"
    assert args.checkpoint.replace("_", "").isalnum()
    checkpoint = run / "mynpu/pnr/checkpoints" / (args.checkpoint + ".enc")
    database = checkpoint.with_suffix(".enc.dat")
    assert checkpoint.is_file() and database.is_dir(), checkpoint
    out.parent.mkdir(parents=True, exist_ok=True)
    source = out.with_suffix(".source.json")
    logs = run / "captures"
    logs.mkdir(exist_ok=True)
    log = logs / (args.checkpoint + ".log")
    assert not out.exists() and not source.exists() and not log.exists()
    script = run / "scripts/capture.tcl"
    command = ["innovus", "-files", str(script)]
    env = {
        **os.environ,
        "DISPLAY": args.display,
        "CHIP_CHECKPOINT": args.checkpoint,
        "CHIP_PICTURE": str(out),
    }
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=run, env=env, stdout=stream, stderr=subprocess.STDOUT)
    assert (
        result.returncode == 0 and out.is_file() and "CHIP_PICTURE_COMPLETED" in log.read_text()
    ), log
    paths = [
        checkpoint,
        script,
        log,
        run / "manifest.json",
        out,
        *sorted(p for p in database.rglob("*") if p.is_file()),
    ]
    record = dict(
        run=str(run),
        checkpoint=args.checkpoint,
        command=command,
        display=args.display,
        scope="Actual Innovus GUI canvas from the named checkpoint; not a reconstructed diagram or foundry signoff.",
        sha256={str(p): sha(p) for p in paths},
    )
    source.write_text(json.dumps(record, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
