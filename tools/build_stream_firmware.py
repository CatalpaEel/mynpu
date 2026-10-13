"""Build the CPU-in-loop host-streaming firmware image."""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", choices=("8k", "8k-p4"), default="8k")
    parser.add_argument("--runs", type=int, default=1000)
    parser.add_argument("--gcc", default=os.environ.get("RISCV_GCC", "riscv64-unknown-elf-gcc"))
    parser.add_argument("--objcopy", default=os.environ.get("RISCV_OBJCOPY", "riscv64-unknown-elf-objcopy"))
    args = parser.parse_args()
    if args.runs < 1:
        raise SystemExit("--runs must be positive")

    generated = ROOT / "generated" / args.layout
    build = ROOT / "build" / args.layout
    generated.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    elf = build / "stream_firmware.elf"
    binary = build / "stream_firmware.bin"
    subprocess.run(
        [
            args.gcc,
            "-march=rv32imc_zicsr",
            "-mabi=ilp32",
            "-Os",
            "-g",
            "-ffreestanding",
            "-fno-builtin",
            "-fno-pic",
            "-msmall-data-limit=0",
            "-nostdlib",
            "-Wl,--build-id=none",
            "-Wl,--no-relax",
            "-Wl,--gc-sections",
            f"-DSTREAM_RUNS={args.runs}",
            "-T",
            str(ROOT / "sw" / "linker.ld"),
            "-I",
            str(generated),
            str(ROOT / "sw" / "startup.S"),
            str(ROOT / "sw" / "main_stream.c"),
            "-o",
            str(elf),
        ],
        check=True,
    )
    subprocess.run([args.objcopy, "-O", "binary", str(elf), str(binary)], check=True)
    data = binary.read_bytes()
    if len(data) > 0x1BC0:
        raise SystemExit(f"stream firmware overlaps reserved stack: {len(data)} bytes")
    padded = data + bytes(8192 - len(data))
    (generated / "cpu_stream.hex").write_text(
        "".join(f"{word:08x}\n" for word in struct.unpack("<2048I", padded)),
        encoding="ascii",
    )
    print(f"stream firmware: {len(data)} bytes -> {generated / 'cpu_stream.hex'}")


if __name__ == "__main__":
    main()
