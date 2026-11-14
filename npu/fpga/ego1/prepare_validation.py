"""Build isolated FPGA/ASIC JTAG validation assets from the production firmware.

No checkpoint loading, floating-point quantization, or production artifact edits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
NPU = REPO / "npu"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(destination):
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    original = NPU / "mnist/artifacts"
    for pattern in ("model.json", "params.hex", "input*.hex", "gold*.hex"):
        for source in original.glob(pattern):
            shutil.copy2(source, destination / source.name)
    env = dict(os.environ, NPU_ARTIFACTS_DIR=str(destination), NPU_SHARED_QUANT="1",
               NPU_QUANT_IRQ_WAIT="1", NPU_QUANT_QUEUE_IRQ_WAIT="0",
               NPU_RF_WEIGHT_CACHE="1", NPU_RF_BANK_WORDS="32")
    for script in ("firmware.py", "stream_firmware.py"):
        subprocess.run([sys.executable, str(NPU / "mnist" / script)], env=env, check=True)
    # Preserve exact production single-frame code and model parameters.
    for filename in ("boot.bin", "params.bin"):
        if sha(destination / filename) != sha(original / filename):
            raise RuntimeError(f"Regenerated {filename} differs from the production artifact")
    stream = json.loads((destination / "stream.json").read_text())
    model = json.loads((destination / "model.json").read_text())
    if stream["conv_vector_stream_path"] or not model["shared_quant"]:
        raise RuntimeError("Expected the production QT01 firmware path")
    full = bytearray(16384)
    program = (destination / "stream_boot.bin").read_bytes()
    params = (destination / "params.bin").read_bytes()
    full[:len(program)] = program
    full[0x2000:0x2000 + len(params)] = params
    (destination / "stream_sram.bin").write_bytes(full)
    (destination / "stream_sram.hex").write_text("".join(f"{b:02x}\n" for b in full))
    for sample in range(10):
        codes = bytes(int(v, 16) for v in (destination / f"input{sample}.hex").read_text().split())
        if len(codes) != 784:
            raise RuntimeError("Invalid MNIST input size")
        (destination / f"input{sample}.bin").write_bytes(codes)
    config = json.loads((NPU / "build_config.json").read_text())
    if config != dict(rf_bank_words=32, matrix_queue_depth=4, vector_queue_depth=4,
                      cnn_queue_depth=4, stream_fifo_depth=8):
        raise RuntimeError("Validation bundle must match the production build configuration")
    manifest = {
        "format": "ego1-jtag-validation-v1", "part": "xc7a35tcsg324-1",
        "production_config": config, "entry": 0x80000080,
        "stream": stream, "samples": model["samples"],
        "single_output": 0x80001400, "golden": "recorded independent integer outputs; no live PyTorch rerun",
        "single_firmware_bitidentical": True, "parameters_bitidentical": True,
        "sha256": {p.name: sha(p) for p in sorted(destination.iterdir()) if p.is_file()},
        "chip_sources_sha256": {
            p.relative_to(REPO).as_posix(): sha(p)
            for p in sorted((NPU / "rtl").rglob("*.sv"))
        },
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"VALIDATION ASSETS PASS: {destination}")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    prepare(parser.parse_args().out)
