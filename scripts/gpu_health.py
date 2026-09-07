#!/usr/bin/env python3
"""Prove every GPU can still create a CUDA context and compute.

    scripts/gpu_health.py            # run on lab, inside a torch env

Exits non-zero if any card fails, so it can gate a loop.

This exists because of 2026-09-07: suspending with 8.3GB of live VRAM left
both cards in "Node Reboot Required", and NOTHING visible said so. nvidia-smi
listed both GPUs, reported sane memory, and the already-running llama-server
kept serving. The damage only surfaced eight minutes later when a training run
asked for a NEW context and got:

    Xid 31, MMU Fault: ENGINE CE2_PBDMA0
    uvm encountered global fatal error 0x60, requiring os reboot to recover

So "the box came back and nvidia-smi looks fine" is not a health check.
Allocating on each card is. Any suspend/resume soak test must run this after
every single cycle.
"""

import sys

try:
    import torch
except ImportError:
    print("torch not importable -- run inside a conda env that has it", file=sys.stderr)
    sys.exit(2)


def main() -> int:
    if not torch.cuda.is_available():
        print("FAIL: torch reports no CUDA availability at all")
        return 1

    count = torch.cuda.device_count()
    if count == 0:
        print("FAIL: zero CUDA devices visible")
        return 1

    failures = 0
    for i in range(count):
        try:
            # A real allocation and a real kernel, not just get_device_name --
            # the broken state still answers property queries perfectly.
            t = torch.randn(2048, 2048, device=f"cuda:{i}")
            result = (t @ t).sum().item()
            torch.cuda.synchronize(i)
            free, total = torch.cuda.mem_get_info(i)
            print(
                f"cuda:{i} {torch.cuda.get_device_name(i)}: OK "
                f"(matmul={result:.3e}, {free // 2**20}MiB free of {total // 2**20}MiB)"
            )
            del t
            torch.cuda.empty_cache()
        except Exception as exc:
            print(f"cuda:{i}: FAILED -> {type(exc).__name__}: {exc}")
            failures += 1

    if failures:
        print(f"\n{failures} of {count} GPU(s) unhealthy. Check `dmesg | grep -i xid`.")
        return 1

    print(f"\nAll {count} GPU(s) healthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
