#!/usr/bin/env python3
"""Does a positive GPC clock offset buy throughput at a FIXED power cap?

This is the headless equivalent of an undervolt. At a fixed cap the card picks
the highest voltage/frequency point that fits the budget; a positive clock
offset shifts how much clock each voltage delivers, so the same watts do more
work. No voltage setter exists on consumer GeForce under Linux, and the
nvidia-settings route needs X, so this uses NVML's GpcClkVfOffset (525+).

CORRECTNESS IS THE POINT, NOT THROUGHPUT. An unstable GPU on a training box
does not reliably crash -- it can silently return wrong numbers, and corrupted
gradients that still converge are far worse than a hang. So every step is
compared BIT-EXACT against the offset-0 reference and the run aborts on the
first mismatch or new Xid. Throughput is only interesting if correctness holds.

Unlike gpu_power_sweep.py this does NOT refuse to run while another process
holds the GPU, and that is deliberate. Contention skews throughput but cannot
affect bit-exactness, and correctness is what this script exists to decide --
so it stays usable on a card with a resident service. Read its TFLOPS figures
as indicative only when something else is loaded.

Memory offsets are deliberately never touched: temperature.memory reads N/A on
this driver, so the 3090's hottest component is invisible.

Run as root (setting an offset needs it):
  sudo python3 gpu_offset_test.py --gpu 1 --offsets 50 100 150 200
"""
import argparse, ctypes, os, subprocess, sys, time

os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"

NVML_SUCCESS = 0
nvml = ctypes.CDLL("libnvidia-ml.so.1")


def nvml_dev(idx):
    if nvml.nvmlInit_v2() != NVML_SUCCESS:
        sys.exit("nvmlInit failed")
    d = ctypes.c_void_p()
    if nvml.nvmlDeviceGetHandleByIndex_v2(idx, ctypes.byref(d)) != NVML_SUCCESS:
        sys.exit(f"no NVML handle for index {idx}")
    return d


def get_offset(dev):
    v = ctypes.c_int(0)
    rc = nvml.nvmlDeviceGetGpcClkVfOffset(dev, ctypes.byref(v))
    return v.value if rc == NVML_SUCCESS else None


def set_offset(dev, mhz):
    rc = nvml.nvmlDeviceSetGpcClkVfOffset(dev, ctypes.c_int(mhz))
    return rc


def smi(gpu, fields):
    out = subprocess.run(
        ["nvidia-smi", f"--query-gpu={','.join(fields)}",
         "--format=csv,noheader,nounits", "-i", str(gpu)],
        capture_output=True, text=True).stdout.strip()
    return [v.strip() for v in out.split(",")]


def xid_count():
    out = subprocess.run(["dmesg"], capture_output=True, text=True).stdout
    return out.count("Xid")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gpu", type=int, default=1)
    ap.add_argument("--offsets", type=int, nargs="*", default=[50, 100, 150, 200])
    ap.add_argument("--size", type=int, default=8192)
    ap.add_argument("--warmup", type=float, default=20)
    ap.add_argument("--measure", type=float, default=30)
    ap.add_argument("--check-iters", type=int, default=300)
    args = ap.parse_args()

    import torch
    dev_t = f"cuda:{args.gpu}"
    name = smi(args.gpu, ["name"])[0]
    tname = torch.cuda.get_device_name(args.gpu)
    if name.strip() != tname.strip():
        sys.exit(f"device order mismatch: nvidia-smi says {name}, torch says {tname}")

    cap = smi(args.gpu, ["enforced.power.limit"])[0]
    print(f"# {name} cuda:{args.gpu} | power cap {cap} W held constant throughout")
    print(f"# bf16 matmul {args.size}^2 | correctness: {args.check_iters} iters, bit-exact\n")

    dev = nvml_dev(args.gpu)
    start_offset = get_offset(dev)
    if start_offset is None:
        sys.exit("GpcClkVfOffset not readable")
    print(f"# starting offset {start_offset} MHz")

    # Deterministic inputs, so results are comparable bit-for-bit.
    torch.manual_seed(1234)
    a = torch.randn(args.size, args.size, dtype=torch.bfloat16).to(dev_t)
    b = torch.randn(args.size, args.size, dtype=torch.bfloat16).to(dev_t)
    flops_per = 2.0 * args.size ** 3

    def throughput():
        def spin(duration):
            n, t0 = 0, time.perf_counter()
            while time.perf_counter() - t0 < duration:
                for _ in range(10):
                    a @ b
                torch.cuda.synchronize()
                n += 10
            return n, time.perf_counter() - t0
        spin(args.warmup)
        n, el = spin(args.measure)
        return (n * flops_per) / el / 1e12

    def correctness(reference):
        """Bit-exact against the reference, repeatedly -- sporadic corruption is
        the failure mode that matters, so one comparison is not enough."""
        bad = 0
        for _ in range(args.check_iters):
            if not torch.equal(a @ b, reference):
                bad += 1
        return bad

    xid0 = xid_count()
    reference = (a @ b).clone()
    torch.cuda.synchronize()

    results = []
    try:
        for off in [0] + list(args.offsets):
            rc = set_offset(dev, off)
            if rc != NVML_SUCCESS:
                print(f"  {off:+5d} MHz  set failed rc={rc} (needs root?) -- stopping")
                break
            time.sleep(2)
            applied = get_offset(dev)
            if applied != off:
                print(f"  {off:+5d} MHz  read back as {applied} -- stopping")
                break

            bad = correctness(reference)
            tf = throughput()
            w, t, sm = smi(args.gpu, ["power.draw", "temperature.gpu", "clocks.sm"])
            new_xid = xid_count() - xid0

            status = "OK" if (bad == 0 and new_xid == 0) else \
                     f"CORRUPT ({bad}/{args.check_iters} mismatches, {new_xid} new Xid)"
            print(f"  {off:+5d} MHz  {tf:6.2f} TFLOPS  {w:>6}W  {t:>3}C  "
                  f"{sm:>5}MHz  {status}", flush=True)
            results.append((off, tf, float(w), bad, new_xid))

            if bad or new_xid:
                print("  -> aborting: an unstable offset can silently corrupt "
                      "training, so this is a hard stop.", flush=True)
                break
    finally:
        set_offset(dev, start_offset)
        time.sleep(1)
        print(f"\n# restored offset to {get_offset(dev)} MHz, "
              f"cap still {smi(args.gpu, ['enforced.power.limit'])[0]} W")

    clean = [r for r in results if r[3] == 0 and r[4] == 0]
    if len(clean) > 1:
        base = clean[0][1]
        print(f"\n# gain at a constant {cap} W cap, vs offset 0 ({base:.2f} TFLOPS):")
        for off, tf, w, _, _ in clean:
            print(f"  {off:+5d} MHz  {tf:6.2f} TFLOPS  {100*(tf/base-1):+5.1f}%  {w:6.1f}W")
    nvml.nvmlShutdown()


if __name__ == "__main__":
    sys.exit(main())
