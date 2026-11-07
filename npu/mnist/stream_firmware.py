"""Two SRAM input slots, shared scratch, concurrent host DMA and CNN inference."""

from pathlib import Path
import json, struct, os

ROOT = Path(__file__).resolve().parent
OUT = Path(os.environ.get("NPU_ARTIFACTS_DIR", ROOT / "artifacts")).resolve()
meta = json.loads((OUT / "model.json").read_text())
import firmware as fw
from firmware import *

reset()


def xori(rd, rs, imm):
    emit(((imm & 4095) << 20) | (rs << 15) | (4 << 12) | (rd << 7) | 0x13, "xori")


A = 0x80001360
B = 0x80001670
C = 0x80001980
PACKETS = 0x80001C90
MAIL = 0x80001FA0
DESC = 0x80000000 + DESC_BASE
stream_fields = make_layer_fields(A, B, A)
label("_start")
li(5, 1 << 16)
emit((0x304 << 20) | (5 << 15) | (1 << 12) | 0x73, "csrw mie")
emit((0x300 << 20) | (8 << 15) | (7 << 12) | 0x73, "csrci mstatus,8")
li(6, 0x40000600)
emit_platform_check()
li(12, MAIL)
li(19, 0)
li(20, 0)
li(21, 0)
li(25, A)
li(27, 0)
li(28, 0)
lw(22, 12, 24)
branch(22, 0, "frame")
jump("fail")
label("frame")
shift(23, 21, 2, 1)
alu(23, 23, 12, 0)
addi(24, 19, 1)
label("ready")
lw(8, 23, 0)
branch(8, 24, "ready")
alu(26, 25, 20, 0)
li(7, DESC)
li(13, 0)
setup_writes = 0
for i, fields in enumerate(stream_fields):
    emit_layer(i, fields, stream_fields[i - 1] if i else None, stream=True)
# Copy packed logits before granting ownership of the input slot back to host.
li(30, PACKETS)
shift(17, 21, 4, 1)
alu(30, 30, 17, 0)
for off in (0, 4, 8):
    lw(8, 26, off)
    if off == 8:
        shift(8, 8, 16, 1)
        shift(8, 8, 16, 5)
    sw(8, 30, off)
addi(7, 26, 0)
lw(11, 7, 0)
andi(8, 11, 255)
li(9, 0)
li(10, 1)
li(16, 10)
label("argmax")
shift(11, 11, 8, 5)
andi(17, 10, 3)
branch(17, 0, "loaded")
addi(7, 7, 4)
lw(11, 7, 0)
label("loaded")
andi(18, 11, 255)
bge(8, 18, "skip")
addi(8, 18, 0)
addi(9, 10, 0)
label("skip")
addi(10, 10, 1)
branch(10, 16, "argmax")
sw(9, 30, 12)
sw(9, 23, 16)
sw(27, 12, 32)
sw(28, 12, 36)
sw(24, 23, 8)
addi(19, 19, 1)
branch(19, 22, "more")
jump("success")
label("more")
xori(21, 21, 1)
li(20, 0)
branch(21, 0, "slot1")
jump("frame")
label("slot1")
li(20, C - A)
jump("frame")
label("success")
li(6, 0x40000000)
li(5, 0x600D0001)
sw(5, 6, 4)
jump("halt")
label("fail")
li(6, 0x40000000)
li(5, 0xBAD00001)
sw(5, 6, 4)
label("halt")
jump("halt")
resolve()
assert 0x80 + len(code) * 4 <= DESC_BASE, len(code)
image = bytearray(PROGRAM_BYTES)
write_task_table(image)
for i, w in enumerate(code):
    struct.pack_into("<I", image, 0x80 + 4 * i, w)
h = 28
cin = 1
for i, L in enumerate(meta["layers"]):
    out = [14, 14, 7, 3, 3, 1][i]
    cout = L["shape"][0]
    fields = stream_fields[i]
    for j, w in enumerate(fields):
        struct.pack_into("<I", image, DESC_BASE + i * 56 + j * 4, w)
    h = out
    cin = cout
(OUT / "stream_boot.hex").write_text("".join(f"{v:02x}\n" for v in image))
(OUT / "stream_boot.bin").write_bytes(image)
(OUT / "stream_boot.S").write_text("\n".join(listing))
(OUT / "stream.json").write_text(
    json.dumps(
        dict(
            input_slots=[A, C],
            scratch=B,
            output_packets=PACKETS,
            mailbox=MAIL,
            descriptor=DESC,
            raw_result_regfile_words=32,
            rf_bank_words=RF_BANK_WORDS,
            layer_destinations=[f[3] for f in stream_fields],
            conv_vector_stream_path=not SHARED_QUANT,
            matrix_outer_rows=4,
            matrix_outer_cols=4,
            fc_execution_unit="matrix",
            fc_raw_base=fc_raw_base(stream_fields[-1]),
            xbar_cache_data_bytes=0,
            setup_writes=fw.setup_writes,
            firmware_bytes=len(image),
            instructions=len(code),
        ),
        indent=2,
    )
)
print("Stream firmware instructions", len(code))
