"""Run the quantized MNIST model over the complete test set.

This regression deliberately has two references:

* the FBGEMM PyTorch model reconstructed from ``model_int8.pt``; and
* the integer-only implementation used by the RTL (descriptor memory,
  int8 weights, int32 bias, Q31 multiplier and arithmetic right shift).

The latter is independent of PyTorch's runtime rounding details.  It is the
reference for the actual NPU image.  A deterministic random subset is also
written as byte/code vectors for the RTL multi-run testbench.
"""

from __future__ import annotations

import argparse
import json
import random
import struct
import sys
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def load_memory(layout: str):
    generated = ROOT / "cnn_npu_int8" / "generated" / layout
    metadata = json.loads((generated / "golden.json").read_text())
    memory = bytearray(
        int(x, 16) for x in (generated / "cnn_npu_mem.hex").read_text().split()
    )
    return memory, metadata


def descriptor(memory: bytearray, metadata: dict, index: int):
    return struct.unpack_from(
        "<9I", memory, metadata["descriptor_base"] + index * 36
    )


def integer_inference(codes: np.ndarray, memory: bytearray, metadata: dict) -> np.ndarray:
    """Evaluate a batch with the exact arithmetic implemented in cnn_npu_top."""

    x = np.asarray(codes, dtype=np.uint8)
    if x.ndim == 3:
        x = x[:, None, :, :]
    if x.ndim != 4:
        raise ValueError(f"expected NCHW input codes, got {x.shape}")

    for layer_index in range(6):
        src, dst, weight_base, bias_base, mult_base, shift_base, shape, out, quant = descriptor(
            memory, metadata, layer_index
        )
        ih, iw, ic, oc = [(shape >> (8 * k)) & 0xFF for k in range(4)]
        oh, ow, stride, flags = [(out >> (8 * k)) & 0xFF for k in range(4)]
        iz, oz, qmax = [(quant >> (8 * k)) & 0xFF for k in range(3)]

        bias = np.frombuffer(
            memoryview(memory)[bias_base : bias_base + 4 * oc], dtype="<i4"
        ).astype(np.int64)
        multiplier = np.frombuffer(
            memoryview(memory)[mult_base : mult_base + 4 * oc], dtype="<u4"
        ).astype(np.int64)
        shift = np.frombuffer(memoryview(memory)[shift_base : shift_base + oc], dtype=np.uint8)
        terms = ic * (1 if flags & 1 else 9)
        if flags & 4:
            packed = np.frombuffer(memoryview(memory)[weight_base:weight_base+((oc+3)//4)*terms*4], dtype=np.int8)
            weight_matrix = packed.reshape(-1,terms,4).transpose(0,2,1).reshape(-1,terms)[:oc].astype(np.int64)
        else:
            weight_matrix = np.frombuffer(memoryview(memory)[weight_base:weight_base+oc*terms],dtype=np.int8).reshape(oc,terms).astype(np.int64)

        if flags & 1:  # FC: 1x1xCin, one output vector per image.
            if x.shape[1:] != (1, 1, ic):
                x = x.reshape(x.shape[0], -1)[:, None, None, :]
            flat = x.reshape(x.shape[0], ic).astype(np.int64)
            weights = weight_matrix
            raw = (flat - iz) @ weights.T + bias[None, :]
            pixels = 1
        else:
            if x.shape[1:] != (ic, ih, iw):
                raise ValueError(
                    f"layer {layer_index} shape mismatch: got {x.shape[1:]}, "
                    f"expected {(ic, ih, iw)}"
                )
            weights = weight_matrix.reshape(oc,ic,3,3)
            # The RTL treats padding as the input zero point and stores tensors
            # channel-major.  Build an im2col matrix in that same order.
            padded = np.full(
                (x.shape[0], ic, ih + 2, iw + 2), iz, dtype=np.int64
            )
            padded[:, :, 1 : ih + 1, 1 : iw + 1] = x
            pixels = oh * ow
            patches = np.empty((x.shape[0], pixels, ic * 9), dtype=np.int64)
            p = 0
            for y in range(oh):
                for xx in range(ow):
                    patch = padded[
                        :, :, y * stride : y * stride + 3, xx * stride : xx * stride + 3
                    ]
                    patches[:, p, :] = patch.reshape(x.shape[0], -1)
                    p += 1
            raw = (patches - iz) @ weights.reshape(oc, -1).T
            raw += bias[None, None, :]
            # [N, pixels, channels] -> channel-major [N, channels*pixels].
            raw = np.transpose(raw, (0, 2, 1)).reshape(x.shape[0], oc * pixels)

        # The accumulator is a signed 32-bit register in the RTL.
        raw = ((raw + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)
        products = raw * np.repeat(multiplier, pixels)[None, :]
        rounded = np.empty_like(products)
        for channel, amount in enumerate(shift.tolist()):
            begin = channel * pixels
            end = begin + pixels
            if amount:
                rounded[:, begin:end] = (products[:, begin:end] + (1 << (amount - 1))) >> amount
            else:
                rounded[:, begin:end] = products[:, begin:end]
        rounded += oz
        if flags & 2:
            rounded = np.maximum(rounded, oz)
        x = np.clip(rounded, 0, qmax).astype(np.uint8).reshape(
            x.shape[0], oc, oh, ow
        )

    return x.reshape(x.shape[0], -1)


def write_vectors(path: Path, vectors: np.ndarray):
    with path.open("w", encoding="ascii") as stream:
        for vector in vectors.reshape(-1):
            stream.write(f"{int(vector):02x}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", choices=("8k", "16k", "8k-p4"), default="8k")
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--random-vectors", type=int, default=64)
    parser.add_argument("--seed", type=int, default=14596)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument(
        "--output-dir", type=Path, default=ROOT / "build" / "mnist-regression"
    )
    args = parser.parse_args()

    try:
        import torch
        from torchvision import datasets, transforms
        sys.path.insert(0, str(ROOT / "cnn_npu_int8" / "tools"))
        from export_model import build_quantized
    except Exception as exc:  # pragma: no cover - gives a useful CLI error
        raise SystemExit(
            "This regression needs the repository's PyTorch environment (for example "
            "`conda run -n eeml python tools/mnist_regression.py`).\n"
            f"Import failed: {exc}"
        ) from exc

    if args.batch_size < 1 or args.random_vectors < 1:
        raise SystemExit("batch size and random vector count must be positive")

    checkpoint_path = ROOT / "model" / "checkpoints" / "model_int8.pt"
    checkpoint = torch.load(checkpoint_path, map_location="cpu")
    torch.backends.quantized.engine = checkpoint.get("backend", "fbgemm")
    quantized = build_quantized(checkpoint["state_dict"]).eval()

    transform = transforms.Compose(
        [
            transforms.ToTensor(),
            transforms.Normalize((0.1307,), (0.3081,)),
        ]
    )
    dataset = datasets.MNIST(args.data_dir, train=False, download=True, transform=transform)
    memory, metadata = load_memory(args.layout)

    all_torch_predictions = []
    all_integer_predictions = []
    all_labels = []
    all_codes = []
    all_integer_outputs = []
    max_code_error = 0
    mismatch_count = 0

    with torch.no_grad():
        for begin in range(0, len(dataset), args.batch_size):
            end = min(begin + args.batch_size, len(dataset))
            images = torch.stack([dataset[i][0] for i in range(begin, end)])
            labels = torch.tensor([int(dataset[i][1]) for i in range(begin, end)])
            quantized_input = quantized.quant(images)
            codes = quantized_input.int_repr().numpy().astype(np.uint8)
            torch_output = quantized(images)
            torch_predictions = torch_output.argmax(dim=1).numpy()
            integer_output = integer_inference(codes, memory, metadata)
            integer_predictions = integer_output.argmax(axis=1)

            all_codes.append(codes)
            all_integer_outputs.append(integer_output)
            all_torch_predictions.append(torch_predictions)
            all_integer_predictions.append(integer_predictions)
            all_labels.append(labels.numpy())

            mismatch_count += int(np.count_nonzero(torch_predictions != integer_predictions))

    codes = np.concatenate(all_codes, axis=0)
    integer_outputs = np.concatenate(all_integer_outputs, axis=0)
    torch_predictions = np.concatenate(all_torch_predictions)
    integer_predictions = np.concatenate(all_integer_predictions)
    labels = np.concatenate(all_labels)

    # Compare the deterministic exported vector against the checked-in golden.
    deterministic = np.asarray(metadata["input_codes"], dtype=np.uint8).reshape(1, 1, 28, 28)
    deterministic_output = integer_inference(deterministic, memory, metadata)[0].tolist()
    sys.path.insert(0, str(ROOT / "tools"))
    from build_firmware import integer_golden
    expected_deterministic = integer_golden(bytes(memory), metadata)[-1]
    if deterministic_output != expected_deterministic:
        raise RuntimeError(
            "integer reference disagrees with tools/build_firmware.py for the exported vector"
        )

    rng = random.Random(args.seed)
    count = min(args.random_vectors, len(dataset))
    selected = rng.sample(range(len(dataset)), count)
    selected_codes = codes[selected]
    selected_outputs = integer_outputs[selected]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_vectors(args.output_dir / f"mnist_input_codes_{args.layout}.hex", selected_codes)
    write_vectors(args.output_dir / f"mnist_integer_outputs_{args.layout}.hex", selected_outputs)
    (args.output_dir / f"mnist_indices_{args.layout}.json").write_text(
        json.dumps({"seed": args.seed, "indices": selected}, indent=2), encoding="utf-8"
    )

    result = {
        "layout": args.layout,
        "samples": len(dataset),
        "torch_int8_accuracy": float(np.mean(torch_predictions == labels) * 100.0),
        "rtl_integer_accuracy": float(np.mean(integer_predictions == labels) * 100.0),
        "torch_vs_integer_prediction_mismatches": mismatch_count,
        "torch_vs_integer_mismatch_indices": np.flatnonzero(torch_predictions != integer_predictions).tolist(),
        "random_vector_count": count,
        "seed": args.seed,
        "random_indices": selected,
        "quantized_input_range": [int(codes.min()), int(codes.max())],
        "rtl_output_range": [int(integer_outputs.min()), int(integer_outputs.max())],
        "checked_in_pytorch_accuracy": metadata.get("state_accuracy", {}).get("int8_accuracy"),
    }
    (args.output_dir / f"mnist_result_{args.layout}.json").write_text(
        json.dumps(result, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
