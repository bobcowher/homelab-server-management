#!/usr/bin/env python3
"""Try to claim N GiB of VRAM on a device, the way a training run would.

Uses the CUDA driver API directly (libcuda.so.1, shipped with the driver) so it
needs no torch. PyTorch's caching allocator bottoms out in the same driver
allocation, so the success/failure behavior here is what a real job would see.

  ./vram_probe.py <device_index> <gib> [hold_seconds]

Device indices match nvidia-smi. Exit 2 means out of memory, 1 any other
CUDA failure.
"""
import ctypes
import os
import sys
import time

# The driver defaults to fastest-first ordering, which puts the 3090 at index 0 --
# the reverse of nvidia-smi. Pin PCI order so indices here match what nvidia-smi
# prints. Must be set before cuInit reads it.
os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"

CUDA_SUCCESS = 0
CUDA_ERROR_OUT_OF_MEMORY = 2


def check(cu, rc, what):
    if rc == CUDA_SUCCESS:
        return
    name = ctypes.c_char_p()
    cu.cuGetErrorName(rc, ctypes.byref(name))
    desc = ctypes.c_char_p()
    cu.cuGetErrorString(rc, ctypes.byref(desc))
    print(f"FAIL  {what}: rc={rc} {name.value.decode()} -- {desc.value.decode()}")
    sys.exit(1 if rc != CUDA_ERROR_OUT_OF_MEMORY else 2)


def main():
    dev_idx = int(sys.argv[1])
    gib = float(sys.argv[2])
    hold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0

    cu = ctypes.CDLL("libcuda.so.1")
    check(cu, cu.cuInit(0), "cuInit")

    dev = ctypes.c_int()
    check(cu, cu.cuDeviceGet(ctypes.byref(dev), dev_idx), f"cuDeviceGet({dev_idx})")

    name = ctypes.create_string_buffer(128)
    cu.cuDeviceGetName(name, 128, dev)

    ctx = ctypes.c_void_p()
    check(cu, cu.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev), "cuCtxCreate")

    free = ctypes.c_size_t()
    total = ctypes.c_size_t()
    check(cu, cu.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total)), "cuMemGetInfo")
    mib = 1024 * 1024
    print(f"device {dev_idx}: {name.value.decode()}")
    print(f"  free {free.value // mib} MiB / total {total.value // mib} MiB")
    print(f"  requesting {gib} GiB ...")

    ptr = ctypes.c_void_p()
    nbytes = ctypes.c_size_t(int(gib * 1024**3))
    rc = cu.cuMemAlloc_v2(ctypes.byref(ptr), nbytes)
    check(cu, rc, f"cuMemAlloc({gib} GiB)")

    print(f"  OK    allocated {gib} GiB")
    if hold:
        print(f"  holding {hold}s")
        time.sleep(hold)
    cu.cuMemFree_v2(ptr)


if __name__ == "__main__":
    main()
