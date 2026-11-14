"""Exercise the real CPU/NPU through OpenOCD Tcl RPC and aligned 32-bit SBA.

Uses only the standard library. Start OpenOCD separately; never programs the FPGA.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import socket
import struct
import time

SRAM, RESULT, CONTROL, ENTRY = 0x80000000, 0x40000004, 0x40000008, 0x4000000C
PASS, FAIL = 0x600D0001, 0xBAD00001


class OpenOCD:
    def __init__(self, host="127.0.0.1", port=6666, timeout=120):
        if host not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("Use a local OpenOCD endpoint or an SSH tunnel")
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.settimeout(timeout)

    def command(self, command):
        wrapped = 'if {[catch {' + command + '} __ego1_r]} {format "ERR %s" $__ego1_r} else {format "OK %s" $__ego1_r}'
        self.sock.sendall(wrapped.encode() + b"\x1a")
        data = bytearray()
        while not data.endswith(b"\x1a"):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("OpenOCD disconnected; reset and reload before retrying")
            data.extend(chunk)
        response = data[:-1].decode().strip()
        if not response.startswith("OK"):
            raise RuntimeError(response)
        return response[2:].strip()

    def read(self, address, count=1):
        if address & 3 or not 1 <= count <= 256:
            raise ValueError("SBA requires aligned 32-bit reads, 1..256 words")
        result = [int(x, 0) for x in self.command(f"read_memory {address:#x} 32 {count}").split()]
        if len(result) != count:
            raise RuntimeError("Short SBA read")
        return result

    def write(self, address, words):
        if address & 3 or not 1 <= len(words) <= 256 or any(not 0 <= w <= 0xFFFFFFFF for w in words):
            raise ValueError("SBA requires aligned 32-bit writes, 1..256 words")
        self.command(f"write_memory {address:#x} 32 {{" + " ".join(hex(w) for w in words) + "}")

    def reset(self):
        # Reset the entire non-debug system, including queues, FIFO and status.
        # The DM survives ndmreset; reassert dmactive before every reset/load.
        self.command("poll off")
        self.command("riscv dmi_write 0x10 1")
        self.command("riscv dmi_write 0x10 3; sleep 10")
        self.command("riscv dmi_write 0x10 0x80000001; sleep 10; halt")
        self.command("riscv set_mem_access sysbus")
        if self.read(CONTROL)[0] != 0 or self.read(RESULT)[0] != 0:
            raise RuntimeError("System reset failed to clear RUN/result")
        capabilities = {0x40000000: 0x4E505532, 0x40000040: 0x00020002,
                        0x40000050: 0x00020020, 0x40000058: 0x56504733,
                        0x40000060: 0x00040008, 0x4000006C: 0x00040404,
                        0x40000070: 0x00070000, 0x40000654: 0x53443935}
        for address, wanted in capabilities.items():
            got = self.read(address)[0]
            if got != wanted:
                raise RuntimeError(f"Wrong bitstream/ABI at {address:#x}: {got:#x} != {wanted:#x}")

    def start(self, entry):
        self.write(RESULT, [0])
        if self.read(RESULT)[0] != 0:
            raise RuntimeError("Stale result did not clear")
        self.write(ENTRY, [entry])
        self.write(CONTROL, [1])
        self.command("resume; poll on")

    def close(self):
        self.sock.close()


def validate_assets(folder):
    manifest = json.loads((folder / "manifest.json").read_text())
    if manifest["format"] != "ego1-jtag-validation-v1":
        raise ValueError("Unknown bundle format")
    for name, expected in manifest["sha256"].items():
        p = folder / name
        if p.parent.resolve() != folder.resolve() or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Asset hash mismatch: {name}")
    for name in ("stream_sram.bin", *(f"sram{i}.bin" for i in range(10))):
        if (folder / name).stat().st_size != 16384:
            raise ValueError(f"Invalid SRAM image size: {name}")
    return manifest


def upload(io, address, payload, chunk_words=64, verify=True):
    if len(payload) % 4:
        raise ValueError("Payload must contain whole words")
    words = struct.unpack(f"<{len(payload)//4}I", payload)
    for i in range(0, len(words), chunk_words):
        block = list(words[i:i + chunk_words])
        io.write(address + i * 4, block)
        if verify and io.read(address + i * 4, len(block)) != block:
            raise RuntimeError(f"SRAM readback mismatch at {address + i*4:#x}")


def wait_value(io, address, expected, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = io.read(address)[0]
        if value == expected:
            return
        if address == RESULT and value != 0:
            raise RuntimeError(f"Firmware failed: {value:#x}")
        if address != RESULT:
            status = io.read(RESULT)[0]
            if status != 0:
                # DONE can change between the two SBA reads, especially on the
                # final frame. Re-read ownership before treating terminal PASS
                # as an early exit.
                if status == PASS and io.read(address)[0] == expected:
                    return
                raise RuntimeError(f"Firmware ended before expected sequence: {status:#x}")
            if value > expected:
                raise RuntimeError(f"Unexpected sequence at {address:#x}: {value} > {expected}")
        time.sleep(0.005)
    raise TimeoutError(f"No progress at {address:#x}; expected {expected:#x}")


def check_output(folder, sample, words):
    got = list(struct.pack("<3I", *words[:3])[:10])
    wanted = [int(v, 16) for v in (folder / f"gold{sample}_5.hex").read_text().split()]
    if got != wanted:
        raise RuntimeError(f"Logits mismatch sample={sample}: {got} != {wanted}")
    return max(range(10), key=got.__getitem__)


def single(io, folder, manifest, sample, timeout):
    io.reset()
    upload(io, SRAM, (folder / f"sram{sample}.bin").read_bytes())
    io.start(manifest["entry"])
    wait_value(io, RESULT, PASS, timeout)
    prediction = check_output(folder, sample, io.read(manifest["single_output"], 3))
    if io.read(0x80001F00)[0] != prediction:
        raise RuntimeError("CPU argmax mismatch")
    return prediction


def continuous(io, folder, manifest, runs, timeout, rng, record):
    io.reset()
    upload(io, SRAM, (folder / "stream_sram.bin").read_bytes())
    stream = manifest["stream"]
    mail = stream["mailbox"]
    io.write(mail, [0] * 16)
    io.write(mail + 24, [runs])
    io.start(manifest["entry"])
    for frame in range(runs):
        sample = rng.randrange(10)
        slot = frame % 2
        seq = frame + 1
        # Only reuse a slot after its previous output was consumed. READY is
        # published last; DONE is the CPU's commit of the complete output packet.
        io.write(stream["output_packets"] + slot * 16, [0xDEADC0DE] * 4)
        payload = (folder / f"input{sample}.bin").read_bytes()
        upload(io, stream["input_slots"][slot], payload)
        time.sleep(rng.uniform(0, 0.01))
        began = time.monotonic()
        io.write(mail + slot * 4, [seq])
        wait_value(io, mail + 8 + slot * 4, seq, timeout)
        words = io.read(stream["output_packets"] + slot * 16, 4)
        prediction = check_output(folder, sample, words)
        if words[3] != prediction or io.read(mail + 16 + slot * 4)[0] != prediction:
            raise RuntimeError("CPU packet/mailbox argmax mismatch")
        if io.read(mail + 8 + slot * 4)[0] != seq:
            raise RuntimeError("DONE sequence changed while reading output")
        record({"frame": frame, "sample": sample, "slot": slot, "sequence": seq,
                "prediction": prediction, "host_roundtrip_s": time.monotonic() - began})
    wait_value(io, RESULT, PASS, timeout)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--assets", type=Path, required=True)
    p.add_argument("--mode", choices=("smoke", "reload", "continuous"), default="smoke")
    p.add_argument("--runs", type=int, default=1000)
    p.add_argument("--boots", type=int, default=1)
    p.add_argument("--seed", type=int, default=20261113)
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--rpc-port", type=int, default=6666)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if not 1 <= args.runs <= 65535 or not 1 <= args.boots <= 1000 or args.timeout <= 0:
        p.error("Invalid run/boot count or timeout")
    manifest = validate_assets(args.assets)
    args.out.mkdir(parents=True, exist_ok=False)
    rng = random.Random(args.seed)
    result = {"passed": False, "scope": "physical board via external JTAG/SBA; set only after execution",
              "mode": args.mode, "seed": args.seed, "boots_requested": args.boots,
              "frames_checked": 0, "boot_checks": 0,
              "manifest_sha256": hashlib.sha256((args.assets / "manifest.json").read_bytes()).hexdigest()}
    io = None
    with (args.out / "frames.jsonl").open("w") as log:
        def record(item):
            result["frames_checked"] += 1
            log.write(json.dumps(item) + "\n")
            log.flush()
            if result["frames_checked"] % 10 == 0:
                print(f"Checked {result['frames_checked']} frames", flush=True)
        try:
            io = OpenOCD(port=args.rpc_port)
            result["openocd_version"] = io.command("version")
            for boot in range(args.boots):
                if args.mode == "continuous":
                    continuous(io, args.assets, manifest, args.runs, args.timeout, rng,
                               lambda item: record(dict(item, boot=boot)))
                else:
                    sample = boot % 10
                    prediction = single(io, args.assets, manifest, sample, args.timeout)
                    record(dict(boot=boot, sample=sample, prediction=prediction))
                result["boot_checks"] += 1
            result["passed"] = True
            print(f"EGO1 VALIDATION PASS: {result['frames_checked']} frames, {result['boot_checks']} boots")
        except Exception as exc:
            result["error"] = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            if io is not None:
                io.close()
            (args.out / "result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
