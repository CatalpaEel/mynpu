"""Format maintained source files; --check reports drift without writing files."""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("FORMAT_TOOL_DIR", Path.home() / ".cache/mynpu-format/bin"))
SKIP = {"build", "reports", "artifacts", "debug", "__pycache__"}
EXTENSIONS = {".sv", ".svh", ".py", ".h", ".c", ".sh"}


def sources():
    return sorted(
        p
        for folder in [ROOT / "npu", ROOT / "tools"]
        for p in folder.rglob("*")
        if p.is_file()
        and p.suffix in EXTENSIONS
        and not (SKIP - {"debug"}).intersection(p.relative_to(ROOT).parts)
        and not p.is_relative_to(ROOT / "npu/debug")
    )


def tool(name):
    path = CACHE / name
    spec = json.loads((ROOT / "tools/formatters.json").read_text())[name]
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != spec["sha256"]:
        raise SystemExit(f"Missing or unpinned {name}; run 'make format-setup'")
    return str(path)


def formatted(path):
    if path.suffix in {".sv", ".svh"}:
        command = [tool("verible-verilog-format"), "--flagfile=" + str(ROOT / ".verible-format")]
    elif path.suffix == ".py":
        command = [
            tool("ruff"),
            "format",
            "--config",
            str(ROOT / "ruff.toml"),
            "--stdin-filename",
            str(path),
            "-",
        ]
        result = subprocess.run(
            command, input=path.read_bytes(), capture_output=True, check=True
        ).stdout
        if ast.dump(ast.parse(result)) != ast.dump(ast.parse(path.read_bytes())):
            raise SystemExit(f"Python AST changed: {path}")
        return result
    elif path.suffix in {".h", ".c"}:
        command = [tool("clang-format"), "--style=file"]
    else:
        command = [tool("shfmt"), "-ln", "bash", "-i", "2", "-ci", "-sr", "-bn"]
    result = subprocess.run([*command, str(path)], capture_output=True, check=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    changes = []
    paths = sources()
    for path in paths:
        try:
            output = formatted(path)
        except subprocess.CalledProcessError as error:
            raise SystemExit(f"{path}:\n{error.stderr.decode()}") from error
        if output != path.read_bytes():
            changes.append((path, output))
    for path, output in changes:
        print(path.relative_to(ROOT))
        if not args.check:
            path.write_bytes(output)
    print(f"{'Would format' if args.check else 'Formatted'} {len(changes)} / {len(paths)} files")
    return int(args.check and bool(changes))


if __name__ == "__main__":
    raise SystemExit(main())
