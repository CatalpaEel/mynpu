from pathlib import Path
import json, struct, sys, os

ROOT = Path(__file__).resolve().parent
OUT = Path(os.environ.get("NPU_ARTIFACTS_DIR", ROOT / "artifacts")).resolve()
meta = json.loads((OUT / "model.json").read_text())
# Place the single parameter copy in bank1; code and activation ping-pong stay in bank0.
for L in meta["layers"]:
    if L["weights"] < 0x80002000:
        L["weights"] += 0x1C00
        L["quant"] += 0x1C00
meta["parameter_base"] = 0x80002000
sys.path.insert(0, str(ROOT.parent / "sw"))
from rv32_asm import *

A = 0x80001360
RF_BASE = 0x80004000
RF_BANK_WORDS = int(
    os.environ.get(
        "NPU_RF_BANK_WORDS",
        json.loads((ROOT.parent / "build_config.json").read_text())["rf_bank_words"],
    )
)
RF_BANK_BYTES = RF_BANK_WORDS * 4
setup_writes = 0
# Production default: the shared QT01 path owns inference postprocessing.
SHARED_QUANT = os.environ.get("NPU_SHARED_QUANT", "1") == "1"
QUANT_IRQ_WAIT = SHARED_QUANT and os.environ.get("NPU_QUANT_IRQ_WAIT", "1") == "1"
QUANT_QUEUE_IRQ_WAIT = QUANT_IRQ_WAIT and os.environ.get("NPU_QUANT_QUEUE_IRQ_WAIT", "0") == "1"


def lbu(rd, base, off):
    emit(((off & 4095) << 20) | (base << 15) | (4 << 12) | (rd << 7) | 3, "lbu")


def shift(rd, rs, imm, fun):
    emit((imm << 20) | (rs << 15) | (fun << 12) | (rd << 7) | 0x13, "shift")


def alu(rd, a, b, fun):
    emit((b << 20) | (a << 15) | (fun << 12) | (rd << 7) | 0x33, "alu")


def bge(a, b, target):
    code.append(("bge", a, b, target))
    listing.append("    bge")


def make_layer_fields(input_base, sram_scratch, output_base):
    """Reuse RF live ranges; only current input and next output must coexist.

    Prefer distinct RF banks. A tensor may span banks, and a small output may
    use the free tail after the current input. Spill only if no disjoint range
    fits in the entire RF, not merely because it exceeds one bank.
    """
    fields = []
    h = 28
    cin = 1
    src = input_base
    input_bytes = 784
    rf_end = RF_BASE + 2 * RF_BANK_BYTES - 32
    for i, L in enumerate(meta["layers"]):
        out = [14, 14, 7, 3, 3, 1][i]
        cout = L["shape"][0]
        output_bytes = out * out * cout
        dst = None
        if i == 5:
            dst = output_base
        else:
            candidates = [RF_BASE, RF_BASE + RF_BANK_BYTES, (src + input_bytes + 3) & ~3]
            for candidate in candidates:
                within = RF_BASE <= candidate and candidate + output_bytes <= rf_end
                overlap = candidate < src + input_bytes and src < candidate + output_bytes
                if within and not overlap:
                    dst = candidate
                    break
            if dst is None:
                dst = sram_scratch if src != sram_scratch else input_base
        fields.append(
            [
                src,
                L["weights"],
                L.get("matrix_quant", L["quant"]) if i == 5 else L["quant"],
                dst,
                144 if i == 5 else h,
                1 if i == 5 else h,
                1 if i == 5 else cin,
                cout,
                L["stride"],
                out,
                out,
                L["in_zero"],
                L["out_zero"],
                int(i == 5),
            ]
        )
        src = dst
        h = out
        cin = cout
        input_bytes = output_bytes
    return fields


def prepare_fc_parameters():
    """Keep weights single-copy; append software-generated zero-point constants.

    Matrix consumes signed INT8 a=u-128. Its dot needs (128-iz)*sum(w)
    added before scaling. VPG3 adds offset to the raw dot in INT32, then
    forms a software-owned product pair using only 32-bit instructions.
    """
    layer = meta["layers"][-1]
    original_end = layer["quant"] - 0x80002000 + layer["shape"][0] * 8
    blob = bytearray(int(v, 16) for v in (OUT / "params.hex").read_text().split())[:original_end]
    layer["matrix_quant"] = 0x80002000 + len(blob)
    for co in range(layer["shape"][0]):
        begin = layer["weights"] - 0x80002000 + co * 144
        weights = struct.unpack("144b", blob[begin : begin + 144])
        multiplier, bias = struct.unpack_from("<ii", blob, layer["quant"] - 0x80002000 + co * 8)
        offset = (128 - layer["in_zero"]) * sum(weights)
        # Conservative bound for every possible signed-INT8 input, not just
        # the ten regression samples: raw + offset must fit signed INT32.
        assert 128 * sum(abs(w) for w in weights) + abs(offset) < 2**31
        blob.extend(struct.pack("<iii", multiplier, bias, offset))
    meta["parameter_bytes"] = len(blob)
    meta["fc_execution"] = (
        "4x4 outer-product GEMM; FC 1x4/1x4/1x2 blocks, K16, B leading dimension144"
    )
    (OUT / "params.hex").write_text("".join(f"{v:02x}\n" for v in blob))


prepare_fc_parameters()

layer_fields = make_layer_fields(0x80001400, 0x80001800, 0x80001400)


DESC_BASE = 0xD00
TASK_BASE = DESC_BASE + 6 * 56
PROGRAM_BYTES = 0x1300
assert PROGRAM_BYTES <= A
stream_commands = []
task_ranges = []
for i, fields in enumerate(layer_fields):
    start = TASK_BASE + len(stream_commands) * 4
    per_channel = fields[10] * ((fields[9] + 7) // 8) if i < 5 else 0
    if i < 5:
        for co in range(fields[7]):
            for y in range(fields[10]):
                rows = sum((0 <= y * fields[8] + r - 1 < fields[5]) << r for r in range(3))
                for x in range(0, fields[9], 8):
                    n = min(8, fields[9] - x)
                    left = int(x == 0)
                    right = int((x + n - 1) * fields[8] + 1 >= fields[4])
                    assert y < 128 and x < 128
                    stream_commands.append(
                        y << 16
                        | x << 9
                        | (n - 1)
                        | rows << 4
                        | left << 7
                        | right << 8
                        | ((y * fields[9] + x) << 23 if SHARED_QUANT else 0)
                    )
    task_ranges.append(dict(address=0x80000000 + start, per_channel=per_channel))
assert TASK_BASE + len(stream_commands) * 4 <= PROGRAM_BYTES


def write_task_table(image):
    for j, word in enumerate(stream_commands):
        struct.pack_into("<I", image, TASK_BASE + j * 4, word)


def vector_instruction(op, rd, ra, rb=0, immediate=None):
    """VPG3 low-to-high: opcode5, immediate1, rd2, ra2, rb2, immediate20."""
    return (
        op
        | rd << 6
        | ra << 8
        | rb << 10
        | (0 if immediate is None else 1 << 5 | (immediate & 0xFFFFF) << 12)
    )


def vector_pair_shift(rd, low, high, amount=24, rounded=True):
    assert 0 <= amount <= 32
    return vector_instruction(22 if rounded else 21, rd, low, high) | amount << 12


def emit_vector_program(i):
    # r1=M, r2=bias; r3 is the low product word and then task scalar.
    if i == 0:
        words = [
            vector_instruction(27, 2, 1, immediate=4),
            vector_instruction(27, 1, 1, immediate=0),
            vector_instruction(24, 3, 0, 1),
            vector_instruction(20, 0, 0, 1),
            vector_instruction(16, 3, 3, 2),
            vector_instruction(23, 0, 0, 2),
            vector_pair_shift(0, 3, 0),
            vector_instruction(29, 3, 0),
            vector_instruction(1, 0, 0, 3),
            vector_instruction(5, 0, 0, 3),
            vector_instruction(4, 0, 0, immediate=255),
        ]
        for slot, word in enumerate(words):
            li(8, word)
            sw(8, 14, 0x40 + slot * 4)
        li(8, 0x20B)
        sw(8, 14, 0x34)


RF_WEIGHT_CACHE = int(os.environ.get("NPU_RF_WEIGHT_CACHE", "1")) != 0


def rf_weight_stage_bytes(fields):
    """Use RF only when current input/output are both in SRAM and the complete
    layer's weights fit before the partial-sum workspace. The copy is transient,
    word-aligned, and completed before any producer/consumer task is submitted.
    """
    size = (fields[6] * fields[7] * 9 + 3) & ~3
    rf_end = RF_BASE + 2 * RF_BANK_BYTES
    tensors_in_rf = any(RF_BASE <= fields[k] < rf_end for k in (0, 3))
    return (
        size
        if RF_WEIGHT_CACHE
        and not tensors_in_rf
        and size <= 2 * RF_BANK_BYTES - 32
        and fields[1] % 4 == 0
        else 0
    )


def quant_wait(base, submitted, completed, tag):
    """Independent IRQ16/18 wakes WFI; tickets determine batch completion.

    All engines support bit3 done acknowledgement while active. Clear before
    checking tickets; fresh simultaneous events remain pending in hardware.
    Error levels also wake the CPU and are checked before sleeping again.
    """
    lw(5, base, submitted)
    label(tag)
    if QUANT_IRQ_WAIT:
        li(8, 8)
        sw(8, base, 0)
    lw(8, base, 4)
    andi(11, 8, 4)
    branch(11, 0, "fail")
    lw(8, base, completed)
    if not QUANT_IRQ_WAIT:
        branch(8, 5, tag)
        return
    branch(8, 5, tag + "_sleep")
    jump(tag + "_done")
    label(tag + "_sleep")
    emit(0x10500073, "wfi")
    jump(tag)
    label(tag + "_done")
    li(8, 8)
    sw(8, base, 0)


def quant_settings(fields, matrix=False):
    # x16 parameter pair/triple, x17 destination; all previous work has drained.
    li(30, 0x40000740 if matrix else 0x40000700)
    lw(8, 16, 0)
    sw(8, 30, 4)
    lw(8, 16, 4)
    sw(8, 30, 8)
    li(8, 24)
    sw(8, 30, 12)
    li(8, fields[12])
    sw(8, 30, 16)
    li(8, 0 if matrix else fields[12])
    sw(8, 30, 20)
    li(8, 255)
    sw(8, 30, 24)
    if matrix:
        lw(8, 16, 8)
    else:
        li(8, 0)
    sw(8, 30, 28)
    sw(17, 30, 32)
    li(8, 3)
    sw(8, 30, 0)


def emit_quant_cnn(i, fields, stream=False):
    # Layer-wide addressing is unchanged. Quant parameters are per channel;
    # finish that channel's queue before changing its immutable settings.
    for field, offset in {0: 8, 4: 20, 6: 28, 8: 32, 11: 44}.items():
        lw(8, 7, i * 56 + field * 4)
        if stream and field == 0 and fields[field] == A:
            alu(8, 8, 20, 0)
        sw(8, 6, offset)
    li(8, RF_BASE + 2 * RF_BANK_BYTES - 32)
    sw(8, 6, 24)
    li(8, 0x80006000)
    sw(8, 6, 16)
    li(8, fields[4] * fields[5])
    sw(8, 6, 36)
    li(8, 0)
    sw(8, 6, 48)
    stage_bytes = rf_weight_stage_bytes(fields)
    if stage_bytes:
        # The previous layer has drained both queues; RF scratch is unowned.
        lw(9, 7, i * 56 + 4)
        li(10, RF_BASE)
        li(11, stage_bytes // 4)
        label("weight_cache" + str(i))
        lw(8, 9, 0)
        sw(8, 10, 0)
        addi(9, 9, 4)
        addi(10, 10, 4)
        addi(11, 11, -1)
        branch(11, 0, "weight_cache" + str(i))
    li(31, 1)
    lw(1, 7, i * 56 + 28)
    lw(16, 7, i * 56 + 8)
    lw(17, 7, i * 56 + 12)
    if stream and fields[3] == A:
        alu(17, 17, 20, 0)
    li(15, task_ranges[i]["address"])
    li(2, task_ranges[i]["per_channel"])
    if stage_bytes:
        li(18, RF_BASE)
    else:
        lw(18, 7, i * 56 + 4)  # software-owned kernel cursor
    label("qchannel" + str(i))
    sw(18, 6, 12)
    quant_settings(fields)
    li(3, 0)
    label("qrow" + str(i))
    lw(8, 15, 0)
    sw(8, 6, 40)
    addi(15, 15, 4)
    label("qspace" + str(i))
    lw(8, 6, 88)
    andi(10, 8, 255)
    shift(8, 8, 16, 5)
    branch(10, 8, "qsubmit" + str(i))
    if QUANT_QUEUE_IRQ_WAIT:
        # A completion can free a slot before this acknowledgement. Re-read
        # occupancy AFTER clearing done, otherwise WFI could miss that event.
        li(8, 8)
        sw(8, 6, 0)
        lw(8, 6, 4)
        andi(11, 8, 4)
        branch(11, 0, "fail")
        lw(8, 6, 88)
        andi(10, 8, 255)
        shift(8, 8, 16, 5)
        branch(10, 8, "qsubmit" + str(i))
        emit(0x10500073, "wfi")
    jump("qspace" + str(i))
    label("qsubmit" + str(i))
    sw(31, 6, 0)
    addi(3, 3, 1)
    branch(3, 2, "qrow" + str(i))
    quant_wait(6, 96, 92, "qdrain" + str(i))
    li(8, fields[9] * fields[10])
    alu(17, 17, 8, 0)
    addi(16, 16, 8)
    addi(18, 18, fields[6] * 9)
    addi(1, 1, -1)
    branch(1, 0, "qchannel" + str(i))
    li(8, 0)
    sw(8, 30, 0)


def emit_outer_fc_raw(i, fields, stream=False):
    """Reuse each activation across 4 output channels; weights remain single-copy.

    B is transposed with leading dimension144, so nine K16 tasks update
    1x4/1x4/1x2 blocks. Shared strides are immutable until the queue drains.
    """
    li(13, 0x40000100)
    li(14, 0x40000200)
    li(31, 1)
    lw(15, 7, i * 56)
    lw(16, 7, i * 56 + 8)
    lw(17, 7, i * 56 + 12)
    if stream and fields[3] == A:
        alu(17, 17, 20, 0)
    lw(18, 7, i * 56 + 4)
    li(29, fc_raw_base(fields))
    addi(9, 15, 0)
    li(10, 0x80808080)
    li(11, 36)
    label("outer_fc_recenter")
    lw(8, 9, 0)
    alu(8, 8, 10, 4)
    sw(8, 9, 0)
    addi(9, 9, 4)
    addi(11, 11, -1)
    branch(11, 0, "outer_fc_recenter")
    li(8, 1)
    sw(8, 13, 20)
    li(8, 16)
    sw(8, 13, 28)
    li(8, 0)
    sw(8, 13, 52)
    li(8, 144)
    sw(8, 13, 56)
    li(8, 0)  # precision INT8
    sw(8, 13, 60)
    li(8, 1)  # storage spacing: one byte per operand
    sw(8, 13, 64)
    li(1, 3)
    label("outer_fc_block")
    li(3, 4)
    li(11, 1)
    branch(1, 11, "outer_fc_full")
    li(3, 2)
    label("outer_fc_full")
    sw(3, 13, 24)
    sw(29, 13, 16)
    addi(9, 15, 0)
    addi(10, 18, 0)
    li(2, 9)
    li(4, 2)
    label("outer_fc_tile")
    sw(9, 13, 8)
    sw(10, 13, 12)
    sw(4, 13, 48)
    label("outer_fc_space")
    lw(8, 13, 36)
    andi(11, 8, 255)
    shift(8, 8, 16, 5)
    branch(11, 8, "outer_fc_submit")
    jump("outer_fc_space")
    label("outer_fc_submit")
    sw(31, 13, 0)
    li(4, 6)
    addi(9, 9, 16)
    addi(10, 10, 16)
    addi(2, 2, -1)
    branch(2, 0, "outer_fc_tile")
    addi(18, 18, 576)
    addi(29, 29, 16)
    addi(1, 1, -1)
    branch(1, 0, "outer_fc_block")
    quant_wait(13, 44, 40, "outer_fc_raw_drain")
    li(8, 0)
    sw(8, 13, 56)
    li(29, fc_raw_base(fields))


def emit_quant_fc(i, fields, stream=False):
    # Raw batched outer products; each channel then uses K=0, ACCUMULATE
    # to export its completed INT32 D through the optional quantizer.
    emit_outer_fc_raw(i, fields, stream)
    li(8, 1)
    sw(8, 13, 20)
    sw(8, 13, 24)
    li(8, 0)
    sw(8, 13, 28)
    li(8, 4)
    sw(8, 13, 48)
    li(1, 10)
    label("outer_fc_quant_channel")
    quant_settings(fields, True)
    sw(29, 13, 16)
    sw(31, 13, 0)
    quant_wait(13, 44, 40, "outer_fc_quant_drain")
    li(8, 0)
    sw(8, 30, 0)
    addi(29, 29, 4)
    addi(17, 17, 1)
    addi(16, 16, 12)
    addi(1, 1, -1)
    branch(1, 0, "outer_fc_quant_channel")


def emit_cnn_rows(i, fields, previous, stream=False):
    """Software prepares window tasks; input and kernel stay shared until drain."""
    global setup_writes
    if SHARED_QUANT:
        return emit_quant_cnn(i, fields, stream)
    assert not fields[13]
    mapping = {0: 8, 4: 0x14, 6: 0x1C, 8: 0x20, 11: 0x2C}
    for field, offset in mapping.items():
        if previous is None or fields[field] != previous[field]:
            lw(5, 7, i * 56 + field * 4)
            if stream and field == 0 and fields[field] == A:
                alu(5, 5, 20, 0)
            sw(5, 6, offset)
            setup_writes += 1
    if previous is None:
        li(14, 0x40000200)
        li(31, 1)
        li(8, RF_BASE + 2 * RF_BANK_BYTES - 32)
        sw(8, 6, 0x18)
        li(8, 0x80006000)
        sw(8, 6, 0x10)  # xbar stream channel 0 destination
        sw(8, 14, 8)  # same endpoint, configured once for all convolution layers
        li(8, 0)
        sw(8, 6, 0x30)
    if previous is None or fields[4] * fields[5] != previous[4] * previous[5]:
        li(8, fields[4] * fields[5])
        sw(8, 6, 0x24)
    stage_bytes = rf_weight_stage_bytes(fields)
    if stage_bytes:
        # The previous layer has drained both queues; RF scratch is unowned.
        lw(9, 7, i * 56 + 4)
        li(10, RF_BASE)
        li(11, stage_bytes // 4)
        label("weight_cache" + str(i))
        lw(8, 9, 0)
        sw(8, 10, 0)
        addi(9, 9, 4)
        addi(10, 10, 4)
        addi(11, 11, -1)
        branch(11, 0, "weight_cache" + str(i))
    emit_vector_program(i)
    lw(1, 7, i * 56 + 28)
    li(2, task_ranges[i]["per_channel"])
    if stage_bytes:
        li(18, RF_BASE)
    else:
        lw(18, 7, i * 56 + 4)  # software-owned kernel cursor
    lw(17, 7, i * 56 + 12)
    if stream and fields[3] == A:
        alu(17, 17, 20, 0)
    li(15, task_ranges[i]["address"])
    lw(16, 7, i * 56 + 8)
    count = fields[9] * fields[10]
    if previous is None or count != previous[9] * previous[10]:
        li(8, count)
        sw(8, 14, 0x10)
    if previous is None:
        li(8, 0x120)
        sw(8, 14, 0x14)
    if previous is None or fields[12] != previous[12]:
        lw(8, 7, i * 56 + 48)
        sw(8, 14, 0x30)
    li(4, 8)  # reuse the done-ACK constant across queue/drain checks
    label("channel" + str(i))
    sw(18, 6, 12)
    sw(17, 14, 0x0C)
    sw(16, 14, 0x18)
    label("vector_space" + str(i))
    lw(8, 14, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    lw(8, 14, 0x24)
    andi(10, 8, 255)
    shift(8, 8, 16, 5)
    branch(10, 8, "vector_submit" + str(i))
    jump("vector_space" + str(i))
    label("vector_submit" + str(i))
    sw(31, 14, 0)
    li(3, 0)
    label("row" + str(i))
    lw(8, 15, 0)
    sw(8, 6, 0x28)
    addi(15, 15, 4)
    label("space" + str(i))
    lw(8, 6, 0x58)
    andi(10, 8, 255)
    shift(8, 8, 16, 5)
    branch(10, 8, "submit" + str(i))
    sw(4, 6, 0)
    sw(4, 14, 0)  # acknowledge done only; errors still wake either source
    lw(8, 6, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    lw(8, 14, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    # Recheck after ACK so a completion/slot freed before the ACK is not lost.
    lw(8, 6, 0x58)
    andi(10, 8, 255)
    shift(8, 8, 16, 5)
    branch(10, 8, "submit" + str(i))
    emit(0x10500073, "wfi")
    jump("space" + str(i))
    label("submit" + str(i))
    sw(31, 6, 0)
    addi(3, 3, 1)
    branch(3, 2, "row" + str(i))
    # Kernel is shared: drain CNN before changing it for the next channel.
    lw(5, 6, 0x60)
    label("kernel_drain" + str(i))
    sw(4, 6, 0)
    sw(4, 14, 0)
    lw(8, 6, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    lw(8, 14, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    lw(8, 6, 0x5C)
    branch(8, 5, "kernel_sleep" + str(i))
    jump("kernel_ready" + str(i))
    label("kernel_sleep" + str(i))
    emit(0x10500073, "wfi")
    jump("kernel_drain" + str(i))
    label("kernel_ready" + str(i))
    li(8, count)
    alu(17, 17, 8, 0)
    addi(16, 16, 8)
    addi(18, 18, fields[6] * 9)
    addi(1, 1, -1)
    branch(1, 0, "channel" + str(i))
    sw(4, 6, 0)  # clear the fully drained CNN source before waiting on Vector
    lw(5, 14, 0x2C)
    label("vector_drain" + str(i))
    sw(4, 14, 0)
    lw(8, 14, 4)
    andi(10, 8, 4)
    branch(10, 0, "fail")
    lw(8, 14, 0x28)
    branch(8, 5, "vector_sleep" + str(i))
    jump("vector_drained" + str(i))
    label("vector_sleep" + str(i))
    emit(0x10500073, "wfi")
    jump("vector_drain" + str(i))
    label("vector_drained" + str(i))
    li(8, 2)
    sw(8, 14, 0)
    if stream:
        lw(27, 6, 0x64)
        lw(28, 6, 0x68)


def emit_layer(i, fields, previous, stream=False):
    if fields[13]:
        emit_matrix_fc(i, fields, stream)
    else:
        emit_cnn_rows(i, fields, previous, stream)


def fc_raw_base(fields):
    candidate = RF_BASE + 2 * RF_BANK_BYTES - fields[7] * 4
    return candidate if candidate >= fields[0] + fields[4] else 0x80001800


def emit_matrix_fc(i, fields, stream=False):
    """FC uses 4/4/2 outer-GEMM blocks, then QT01 or general Vector math.

    Each output block receives nine K16 updates, with ACCUMULATE after the
    first tile. Recenter the dead final input in place and keep weights
    single-copy. x19..x28 preserve continuous-input ownership state.
    """
    if SHARED_QUANT:
        return emit_quant_fc(i, fields, stream)
    assert fields[4] == 144 and fields[7] == 10
    emit_outer_fc_raw(i, fields, stream)
    li(8, 2)
    sw(8, 13, 0)
    # Raw FC dot plus its bounded INT32 zero-point correction, then the
    # same general two-word multiply/add/round sequence as convolution.
    words = [
        vector_instruction(27, 2, 1, immediate=4),
        vector_instruction(27, 1, 1, immediate=0),
        vector_instruction(29, 3, 0),
        vector_instruction(1, 0, 0, 3),
        vector_instruction(24, 3, 0, 1),
        vector_instruction(20, 0, 0, 1),
        vector_instruction(16, 3, 3, 2),
        vector_instruction(23, 0, 0, 2),
        vector_pair_shift(0, 3, 0),
        vector_instruction(1, 0, 0, immediate=fields[12]),
        vector_instruction(5, 0, 0, immediate=0),
        vector_instruction(4, 0, 0, immediate=255),
    ]
    for slot, word in enumerate(words):
        li(8, word)
        sw(8, 14, 0x40 + slot * 4)
    li(8, 0x20C)
    sw(8, 14, 0x34)
    li(8, 0x120)  # generic program, memory input, packed U8 output
    sw(8, 14, 0x14)
    li(8, 1)
    sw(8, 14, 0x10)
    # The per-channel offset is written immediately before each FC job.
    li(9, fc_raw_base(fields))
    li(1, 10)
    label("fc_post")
    lw(8, 16, 8)  # per-channel INT32 correction, exposed as task scalar
    sw(8, 14, 0x30)
    sw(9, 14, 8)
    sw(17, 14, 12)
    sw(16, 14, 0x18)
    label("fc_vector_space")
    lw(8, 14, 4)
    andi(11, 8, 4)
    branch(11, 0, "fail")
    lw(8, 14, 0x24)
    andi(11, 8, 255)
    shift(8, 8, 16, 5)
    branch(11, 8, "fc_vector_submit")
    jump("fc_vector_space")
    label("fc_vector_submit")
    sw(31, 14, 0)
    addi(9, 9, 4)
    addi(17, 17, 1)
    addi(16, 16, 12)
    addi(1, 1, -1)
    branch(1, 0, "fc_post")
    lw(5, 14, 0x2C)
    label("fc_vector_drain")
    lw(8, 14, 4)
    andi(11, 8, 4)
    branch(11, 0, "fail")
    lw(8, 14, 0x28)
    branch(8, 5, "fc_vector_drain")
    li(8, 2)
    sw(8, 14, 0)


def emit_platform_check():
    # Match firmware allocation to the instantiated RF capacity before starting
    # any producer. Fail explicitly rather than sending data to a wrong bank.
    lw(8, 6, -0x5B0)
    andi(8, 8, 511)
    li(5, RF_BANK_WORDS)
    branch(8, 5, "fail")
    lw(8, 6, -0x5A8)
    li(5, 0x56504733)
    branch(8, 5, "fail")
    lw(8, 6, -0x594)
    li(5, 0x00040404)
    branch(8, 5, "fail")
    lw(8, 6, -0x590)
    li(5, 0x00070000)
    branch(8, 5, "fail")
    lw(8, 6, 0x54)
    li(5, 0x53443934)
    branch(8, 5, "fail")


def generate_single():
    global setup_writes
    reset()

    label("_start")
    li(5, 0x00070000)
    emit((0x304 << 20) | (5 << 15) | (1 << 12) | 0x73, "csrw mie,x5")
    emit((0x300 << 20) | (8 << 15) | (7 << 12) | 0x73, "csrci mstatus,8")
    li(6, 0x40000600)
    emit_platform_check()
    li(7, 0x80000000 + DESC_BASE)
    li(12, 0x80001F00)
    setup_writes = 0
    for i, fields in enumerate(layer_fields):
        emit_layer(i, fields, layer_fields[i - 1] if i else None)
        li(13, i + 1)
        sw(13, 12, 4)
        lw(5, 12, 12)
        branch(5, 0, "ack" + str(i))
        jump("acked" + str(i))
        label("ack" + str(i))
        lw(8, 12, 8)
        branch(8, 13, "ack" + str(i))
        label("acked" + str(i))
    # FC output is packed quantized logits in buffer A. Compare unsigned values.
    li(7, 0x80001400)
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
    sw(9, 12, 0)
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
    assert 0x80 + len(code) * 4 <= DESC_BASE
    image = bytearray(PROGRAM_BYTES)
    write_task_table(image)
    for i, w in enumerate(code):
        struct.pack_into("<I", image, 0x80 + 4 * i, w)
    h = 28
    cin = 1
    for i, L in enumerate(meta["layers"]):
        out = [14, 14, 7, 3, 3, 1][i]
        cout = L["shape"][0]
        src = layer_fields[i][0]
        dst = layer_fields[i][3]
        fields = [
            src,
            L["weights"],
            layer_fields[i][2],
            dst,
            144 if i == 5 else h,
            1 if i == 5 else h,
            1 if i == 5 else cin,
            cout,
            L["stride"],
            out,
            out,
            L["in_zero"],
            L["out_zero"],
            int(i == 5),
        ]
        for j, w in enumerate(fields):
            struct.pack_into("<I", image, DESC_BASE + i * 56 + j * 4, w)
        L.update(src=src, dst=dst, output_bytes=out * out * cout)
        h = out
        cin = cout
    (OUT / "boot.hex").write_text("".join(f"{v:02x}\n" for v in image))
    (OUT / "boot.S").write_text("\n".join(listing))
    (OUT / "model.json").write_text(json.dumps(meta, indent=2))
    (OUT / "test_meta.svh").write_text(
        f"`define NPU_EXPECTED_MATRIX_JOBS {37 if SHARED_QUANT else 27}\nlocalparam int PROGRAM_BYTES={PROGRAM_BYTES};\nlocalparam int STREAM_TASKS={len(stream_commands)};\n"
        + "localparam int PARAM_BYTES="
        + str(meta["parameter_bytes"])
        + ";\n"
        + "int layer_len[6]='{"
        + ",".join(str(L["output_bytes"]) for L in meta["layers"])
        + "};\n"
        + "int layer_base[6]='{"
        + ",".join(str(f[3]) for f in layer_fields)
        + "};\n"
        + "int prediction[10]='{"
        + ",".join(str(S["prediction"]) for S in meta["samples"])
        + "};\n"
    )
    print("Firmware instructions", len(code), "descriptor writes", setup_writes)
    meta["firmware_bytes"] = len(image)
    meta["setup_writes"] = setup_writes
    meta["rf_bank_words"] = RF_BANK_WORDS
    meta["intermediate_storage"] = "regfile with SRAM spill only for oversized tensors"
    meta["fc_raw_base"] = fc_raw_base(layer_fields[-1])
    meta["rf_weight_stage_bytes"] = [
        rf_weight_stage_bytes(f) if not f[13] else 0 for f in layer_fields
    ]
    meta["stream_abi"] = "SD94"
    meta["stream_task_bits"] = 32
    meta["cnn_kernel_address_per_task"] = False
    meta["stream_tasks"] = len(stream_commands)
    meta["task_table"] = task_ranges
    meta["operator_abi"] = "2.1"
    meta["vector_program_abi"] = "VPG3"
    meta["matrix_precision"] = "INT8"
    meta["matrix_element_bytes"] = 1
    meta["matrix_strides_per_task"] = True
    meta["matrix_stream_order"] = "tile/K/A-rows/B-cols; one FIFO word per operand"
    meta["matrix_execution"] = "4x4 outer product; 16 INT32 accumulators; FC output blocks4/4/2"
    meta["matrix_tasks"] = 37 if SHARED_QUANT else 27
    meta["descriptor_base"] = 0x80000000 + DESC_BASE
    meta["irq_ids"] = {"matrix": 16, "vector": 17, "cnn": 18}
    meta["shared_quant"] = SHARED_QUANT
    meta["queue_space_wait"] = (
        "CNN IRQ18/WFI with occupancy recheck"
        if SHARED_QUANT and QUANT_QUEUE_IRQ_WAIT
        else "polling"
        if SHARED_QUANT
        else "independent IRQ18 CNN / IRQ17 Vector concurrent progress/error wake"
    )
    meta["completion_wait"] = (
        "independent IRQ18 CNN / IRQ16 Matrix, WFI with active done acknowledgement"
        if SHARED_QUANT and QUANT_IRQ_WAIT
        else "polling"
        if SHARED_QUANT
        else "independent IRQ18 CNN / IRQ17 Vector concurrent progress/error wake"
    )
    meta["cnn_output"] = (
        "direct shared quantizer, byte writes to RF/SRAM"
        if SHARED_QUANT
        else "raw signed INT32 routed through xbar channel 0 FIFO to vector"
    )
    meta["postprocessing_unit"] = (
        "shared optional quantizer QT01" if SHARED_QUANT else "generic vector program VPG3"
    )
    (OUT / "model.json").write_text(json.dumps(meta, indent=2))

    (OUT / "boot.bin").write_bytes(image)
    params = bytes(int(line, 16) for line in (OUT / "params.hex").read_text().splitlines())
    (OUT / "params.bin").write_bytes(params)
    for digit in range(10):
        full = bytearray(16384)
        full[: len(image)] = image
        full[0x2000 : 0x2000 + len(params)] = params
        inputs = bytes(
            int(line, 16) for line in (OUT / f"input{digit}.hex").read_text().splitlines()
        )
        full[0x1400 : 0x1400 + 784] = inputs
        struct.pack_into("<I", full, 0x1F00, 0xFFFFFFFF)
        (OUT / f"sram{digit}.bin").write_bytes(full)
        (OUT / f"sram{digit}.hex").write_text("".join(f"{v:02x}\n" for v in full))

    macs = []
    terms = []
    for i, L in enumerate(meta["layers"]):
        if i == 5:
            macs.append(0)
            terms.append(0)
            continue
        h = [28, 14, 14, 7, 3][i]
        out = [14, 14, 7, 3, 3][i]
        c = L["shape"][1]
        co = L["shape"][0]
        valid = sum(0 <= p * L["stride"] + k - 1 < h for p in range(out) for k in range(3))
        macs.append(valid * valid * c * co)
        terms.append(valid * out * c * co)
    with (OUT / "test_meta.svh").open("a") as f:
        f.write("int expected_macs[6]='{" + ",".join(map(str, macs)) + "};\n")
        f.write("int expected_terms[6]='{" + ",".join(map(str, terms)) + "};\n")


if __name__ == "__main__":
    generate_single()
