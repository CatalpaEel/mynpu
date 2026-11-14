"""Check a frozen board bundle before programming or reusing its evidence."""
import argparse
import hashlib
import json
from pathlib import Path


def verify(folder):
    folder = folder.resolve()
    entries = (folder / "MANIFEST.sha256").read_text().splitlines()
    for entry in entries:
        expected, name = entry.split("  ", 1)
        path = (folder / name).resolve()
        if not path.is_relative_to(folder):
            raise ValueError(f"Path outside bundle: {name}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Bundle hash mismatch: {name}")
    build = json.loads((folder / "hardware/source_manifest.json").read_text())
    for name, expected in build["sha256"].items():
        path = (folder / "hardware" / name).resolve()
        if not path.is_relative_to(folder / "hardware"):
            raise ValueError(f"Path outside hardware snapshot: {name}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Frozen build input changed: {name}")
    assets = json.loads((folder / "assets/manifest.json").read_text())
    for name, expected in assets["sha256"].items():
        path = (folder / "assets" / name).resolve()
        if not path.is_relative_to(folder / "assets"):
            raise ValueError(f"Path outside assets: {name}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Validation asset changed: {name}")
    print(f"BOARD BUNDLE VERIFIED: {len(entries)} files, "
          f"{len(build['compiled_sources'])} compiled sources")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    verify(args.bundle)
