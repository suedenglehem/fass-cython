#!/usr/bin/env python3
"""GPU card probe for fass setup.sh (the no-nvidia-smi case).

The nvidia kernel module exposes one directory per card under
/proc/driver/nvidia/gpus/, named by PCI address
(domain:bus:device.function) — even when the nvidia-smi binary (the CUDA
toolkit) is not installed. This lists the cards in the same PCI topology
order nvidia-smi -L uses, one per line:

    GPU 0: NVIDIA GeForce RTX 3090 (PCI 0000:41:00.0)

The card name comes from the directory's `information` file (Model:);
when it is missing or unreadable the line says "NVIDIA GPU".

Exit status: 0 = at least one card visible, 1 = no card (no nvidia
driver module loaded, or the gpus dir is empty).
"""
import os
import re
import sys

GPU_DIR = "/proc/driver/nvidia/gpus"
_BDF = re.compile(r"([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$")


def _bdf_key(bdf):
    m = _BDF.match(bdf)
    if not m:
        # an unexpected directory name: sort it after the real PCI ids
        return (1, 0, 0, 0, 0)
    return (0,) + tuple(int(g, 16) for g in m.groups())


def _model_of(bdf):
    try:
        with open(os.path.join(GPU_DIR, bdf, "information")) as f:
            for line in f:
                if line.startswith("Model:"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "NVIDIA GPU"


def main():
    try:
        entries = sorted(os.listdir(GPU_DIR), key=_bdf_key)
    except OSError:
        return 1  # no nvidia driver module loaded -> no cards
    for i, bdf in enumerate(entries):
        print(f"GPU {i}: {_model_of(bdf)} (PCI {bdf})")
    return 0 if entries else 1


if __name__ == "__main__":
    sys.exit(main())
