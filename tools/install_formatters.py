"""Install checksum-pinned Linux x86_64 formatters into a user-owned cache."""

import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("FORMAT_TOOL_DIR", Path.home() / ".cache/mynpu-format/bin"))


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    archives = {}
    for name, spec in json.loads((ROOT / "tools/formatters.json").read_text()).items():
        target = CACHE / name
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == spec["sha256"]:
            print(f"{name} {spec['version']}: ready")
            continue
        url = spec["url"]
        if url not in archives:
            with urllib.request.urlopen(url, timeout=120) as response:
                archives[url] = response.read()
        data = archives[url]
        if spec["archive"] == "tar":
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                member = next(m for m in archive.getmembers() if m.name.endswith("/" + name))
                data = archive.extractfile(member).read()
        elif spec["archive"] == "zip":
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                member = next(n for n in archive.namelist() if n.endswith("/data/bin/" + name))
                data = archive.read(member)
        if hashlib.sha256(data).hexdigest() != spec["sha256"]:
            raise SystemExit(f"Checksum mismatch: {name}")
        temporary = target.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.chmod(0o755)
        temporary.replace(target)
        print(f"{name} {spec['version']}: installed")


if __name__ == "__main__":
    main()
