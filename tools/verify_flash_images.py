"""Check Flash encodings and exact FPGA frame equality with the Lab6 baseline.

Offline evidence only: this cannot verify physical Flash programming or boot.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNC = bytes.fromhex("aa995566")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bit_payload(path):
    data = path.read_bytes()
    size = struct.unpack_from(">H", data)[0]
    offset = 2 + size
    require(data[offset:offset + 2] == b"\x00\x01", "Invalid .bit header")
    offset += 2
    fields = {}
    while offset < len(data):
        tag = chr(data[offset])
        offset += 1
        width = 4 if tag == "e" else 2
        require(tag in "abcde", "Unknown .bit field")
        size = int.from_bytes(data[offset:offset + width], "big")
        offset += width
        require(offset + size <= len(data), "Truncated .bit field")
        fields[tag] = data[offset:offset + size]
        offset += size
        if tag == "e":
            require(offset == len(data), "Trailing .bit bytes")
            return fields
    raise ValueError("Missing .bit payload")


def writes(payload):
    offset = payload.index(SYNC) + 4
    address = None
    result = []
    while offset < len(payload):
        require(offset + 4 <= len(payload), "Truncated configuration packet")
        header = struct.unpack_from(">I", payload, offset)[0]
        offset += 4
        if header == 0xffffffff:
            continue
        packet_type, opcode = header >> 29, (header >> 27) & 3
        if packet_type == 1:
            address = (header >> 13) & 0x3fff
            count = header & 0x7ff
        else:
            require(packet_type == 2 and address is not None, "Invalid packet type")
            count = header & 0x7ffffff
        require(opcode in (0, 2), "Unexpected read/reserved packet in bitstream")
        if opcode == 2:
            end = offset + count * 4
            require(end <= len(payload), "Truncated configuration data")
            if count:
                result.append((address, payload[offset:end]))
            offset = end
    return result


def mcs_payload(path):
    data = bytearray()
    base, eof = 0, False
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        require(not eof and line.startswith(":"), f"MCS line {line_number}: invalid record")
        row = bytes.fromhex(line[1:])
        require(len(row) >= 5 and len(row) == row[0] + 5 and sum(row) % 256 == 0,
                f"MCS line {line_number}: length/checksum mismatch")
        address, kind, body = int.from_bytes(row[1:3], "big"), row[3], row[4:-1]
        if kind == 0:
            require(base + address == len(data), "MCS gap/overlap or nonzero origin")
            data.extend(body)
        elif kind == 1:
            require(not body and address == 0, "Malformed MCS EOF")
            eof = True
        elif kind in (2, 4):
            require(len(body) == 2 and address == 0, "Malformed MCS address record")
            base = int.from_bytes(body, "big") << (4 if kind == 2 else 16)
        else:
            raise ValueError(f"Unsupported MCS record type {kind}")
    require(eof and data, "Missing MCS EOF/data")
    return bytes(data)


def verify(layout, baseline):
    folder = ROOT / "fpga/ego1/build"
    old = folder / f"ego1_jtag_{layout}.bit"
    require(digest(old.read_bytes()) == baseline["artifacts_sha256"][old.relative_to(ROOT).as_posix()],
            "Original Lab6 bitstream checksum changed")
    paths = [folder / f"ego1_jtag_{layout}_flash.{suffix}" for suffix in ("bit", "mcs", "bin")]
    original, flash = bit_payload(old), bit_payload(paths[0])
    require(flash["b"].rstrip(b"\0") == b"7a35tcsg324", "Wrong FPGA part")
    reference_writes, flash_writes = writes(original["e"]), writes(flash["e"])
    # FAR (1) and FDRI (2) must retain identical addresses and configuration frames,
    # including all BRAM contents. No CPU/NPU/netlist changes are hidden here.
    reference_frames = [(reg, body) for reg, body in reference_writes if reg in (1, 2)]
    frames = [(reg, body) for reg, body in flash_writes if reg in (1, 2)]
    require(frames == reference_frames and any(reg == 2 for reg, _ in frames),
            "FPGA frames differ from verified Lab6 bitstream")
    registers = {reg: int.from_bytes(body, "big") for reg, body in flash_writes if len(body) == 4}
    # Vivado 2023.2 encoding with SPI_BUSWIDTH=4, CONFIGRATE=6 (uncompressed).
    require(registers.get(31) == 0x26b and registers.get(9) == 0x02203fe5,
            "Unexpected SPI configuration registers")
    binary = paths[2].read_bytes()
    require(binary == flash["e"], "BIN differs from .bit configuration payload")
    require(mcs_payload(paths[1]) == binary, "MCS differs from BIN")
    require(len(binary) <= 8 * 1024 * 1024, "Image exceeds 8-MiB Flash")
    checkpoint = (ROOT / "fpga/ego1" / f"vivado_jtag_{layout}" /
                  "ego1_mynpu_jtag.runs/impl_1/ego1_soc_top_routed.dcp")
    return dict(layout=layout, part=baseline["part"], lanes=baseline["lanes"],
                cache_words=baseline["cache_words"], clock_hz=baseline["clock_hz"],
                image_bytes=len(binary), routed_checkpoint_sha256=digest(checkpoint.read_bytes()),
                frames_equal_baseline=True,
                frame_data_sha256=digest(b"".join(body for reg, body in frames if reg == 2)),
                mcs_equals_bin=True, bin_equals_bit_payload=True,
                artifacts_sha256={p.relative_to(ROOT).as_posix(): digest(p.read_bytes()) for p in paths})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/lab6-jtag-flash.json")
    args = parser.parse_args()
    baseline = json.loads((ROOT / "docs/lab6-jtag-fpga.json").read_text())
    records = [verify(r["layout"], r) for r in baseline["records"]]
    result = dict(date="2026-10-19", tool="Vivado 2023.2", interface="SPIx4",
                  flash_mib=8, offset=0, configuration_clock_mhz=6,
                  default_flash_part="n25q64-3.3v-spi-x1_x2_x4",
                  physical_flash_programmed=False, physical_flash_boot_tested=False,
                  external_ft232h_board_tested=False,
                  notes="Offline image checks only. Exact FPGA frame equality to original Lab6 bitstreams. "
                        "No RTL changes; not a new physical-board or ASIC signoff result.", records=records)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print("PASS: private/shared Flash MCS = BIN = bit payload; all FPGA frames equal Lab6 baseline")
    print(args.output)


if __name__ == "__main__":
    main()
