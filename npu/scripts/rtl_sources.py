"""Canonical project RTL list and exact-hash-compatible path relocation."""

from pathlib import Path


def project_sources(npu_root):
    rtl = Path(npu_root) / "rtl"
    paths = []
    for line in (rtl / "files.f").read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            path = rtl / line
            if not path.is_file() or not path.resolve().is_relative_to(rtl.resolve()):
                raise ValueError(f"Invalid RTL entry: {line}")
            paths.append(path)
    if len({p.name for p in paths}) != len(paths):
        raise ValueError("Duplicate RTL basename in files.f")
    if set(paths) != set(rtl.rglob("*.sv")):
        raise ValueError("files.f must list every project .sv exactly once")
    return paths


def rtl_file(npu_root, name):
    return next(p for p in project_sources(npu_root) if p.name == name)


def resolve_recorded_source(project_root, recorded):
    """Resolve an old flat RTL path; callers must still verify its exact hash."""
    root = Path(project_root)
    direct = root / recorded
    if direct.is_file():
        return direct
    path = Path(recorded)
    if path.is_absolute():
        try:
            path = path.relative_to(root)
        except ValueError:
            return direct
    if path.parent == Path("npu/rtl"):
        return rtl_file(root / "npu", path.name)
    return direct
