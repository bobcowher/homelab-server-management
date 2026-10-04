#!/usr/bin/env python3
"""Measure a GPU's power/performance curve, so a power limit is chosen from
data rather than reputation.

Runs an identical bf16 matmul load at each setting -- what training is
bottlenecked on -- and reports achieved TFLOPS, peak core temperature, average
draw and any throttling.

Design notes, all earned:
  * Prints its own hostname and the card's PCI id, so there is no doubt which
    machine and which GPU were measured.
  * Refuses to run if the target GPU already has compute processes; a training
    run would both corrupt the measurement and be slowed by it.
  * Appends each result as it completes, so a run killed partway keeps every
    result it had already earned. The first attempt was killed by a tripped
    breaker and lost everything.
  * Restores the default power limit and unlocks clocks in a finally block.

  python3 gpu_power_sweep.py --gpu 1 --limits 230 260 290 320 350 \
      --out /tmp/sweep_results.jsonl
"""
import argparse, json, os, socket, subprocess, sys, threading, time

# MUST be set before torch initialises CUDA. Without it CUDA orders devices
# FASTEST_FIRST, so on this box torch's cuda:1 is the 3060 while
# `nvidia-smi -i 1` is the 3090 -- and a sweep then benchmarks one card while
# power-limiting the other. That is exactly what happened on the first
# successful run: flat 27 TFLOPS at every limit, 19.6W draw, 210MHz, because
# the measured card was idle and the worked card was never limited.
os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"


def smi(args, sudo=False):
    cmd = (["sudo", "-n"] if sudo else []) + ["nvidia-smi"] + args
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def query(gpu, fields):
    out = smi([f"--query-gpu={','.join(fields)}", "--format=csv,noheader,nounits",
               "-i", str(gpu)])
    return [v.strip() for v in out.split(",")]


class Sampler(threading.Thread):
    """Polls power and temperature while the benchmark runs."""

    def __init__(self, gpu, interval=0.5):
        super().__init__(daemon=True)
        self.gpu, self.interval, self.stop = gpu, interval, False
        self.power, self.temp = [], []

    def run(self):
        while not self.stop:
            try:
                p, t = query(self.gpu, ["power.draw", "temperature.gpu"])
                self.power.append(float(p))
                self.temp.append(float(t))
            except Exception:
                pass
            time.sleep(self.interval)


def throttling(gpu):
    out = smi(["-i", str(gpu), "-q", "-d", "PERFORMANCE"])
    active = []
    for line in out.splitlines():
        if ":" in line:
            name, val = line.rsplit(":", 1)
            if val.strip() == "Active" and name.strip() != "Idle":
                active.append(name.strip())
    return active


def benchmark(dev, n, warmup_s, measure_s):
    import torch
    a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
    b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
    flops_per = 2.0 * n ** 3

    def spin(duration):
        count, t0 = 0, time.perf_counter()
        while time.perf_counter() - t0 < duration:
            for _ in range(10):
                a @ b
            torch.cuda.synchronize()
            count += 10
        return count, time.perf_counter() - t0

    spin(warmup_s)                       # let clocks and temperature settle
    count, elapsed = spin(measure_s)
    return (count * flops_per) / elapsed / 1e12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gpu", type=int, default=1)
    ap.add_argument("--limits", type=int, nargs="*", default=[230, 260, 290, 320, 350])
    ap.add_argument("--clocks", type=int, nargs="*", default=[])
    ap.add_argument("--size", type=int, default=8192)
    ap.add_argument("--warmup", type=float, default=20)
    ap.add_argument("--measure", type=float, default=45)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    dev = f"cuda:{args.gpu}"
    name, default_pl, bus = query(args.gpu, ["name", "power.default_limit", "pci.bus_id"])
    print(f"# host={socket.gethostname()}  {name}  cuda:{args.gpu} ({bus})", flush=True)
    print(f"# default limit {default_pl} W | bf16 matmul {args.size}^2 | "
          f"{args.warmup:.0f}s warmup + {args.measure:.0f}s measured", flush=True)

    # Guard 1: torch and nvidia-smi must name the SAME card for this index.
    # Cheap, and it makes the device-order bug structurally impossible rather
    # than something to remember.
    import torch
    torch_name = torch.cuda.get_device_name(args.gpu)
    if torch_name.strip() != name.strip():
        print(f"# REFUSING: nvidia-smi -i {args.gpu} is '{name}' but torch "
              f"cuda:{args.gpu} is '{torch_name}'. Device order mismatch -- the "
              f"sweep would measure one card and limit another.", flush=True)
        return 1
    print(f"# torch agrees: cuda:{args.gpu} is {torch_name}", flush=True)

    busy = smi(["--query-compute-apps=pid,used_memory", "--format=csv,noheader",
                "-i", str(args.gpu)])
    if busy:
        print(f"# REFUSING: cuda:{args.gpu} already has compute processes:\n{busy}",
              flush=True)
        return 1
    print("", flush=True)

    rows = []
    try:
        plan = [("pl", v) for v in args.limits] + [("lgc", v) for v in args.clocks]
        for kind, value in plan:
            if kind == "pl":
                smi(["-i", str(args.gpu), "-rgc"], sudo=True)
                smi(["-i", str(args.gpu), "-pl", str(value)], sudo=True)
                label = f"{value}W"
            else:
                smi(["-i", str(args.gpu), "-pl", str(int(float(default_pl)))], sudo=True)
                smi(["-i", str(args.gpu), "-lgc", f"0,{value}"], sudo=True)
                label = f"lgc {value}MHz"

            s = Sampler(args.gpu)
            s.start()
            tflops = benchmark(dev, args.size, args.warmup, args.measure)
            s.stop = True
            s.join(timeout=2)

            avg_p = sum(s.power) / len(s.power) if s.power else float("nan")
            max_t = max(s.temp) if s.temp else float("nan")
            sm = query(args.gpu, ["clocks.sm"])[0]
            thr = throttling(args.gpu)

            # Guard 2: if the card we measured was idle, we measured the
            # wrong thing. A real matmul load sits near its power limit; the
            # bogus run averaged 19.6W against a 350W cap. Refuse rather than
            # emit a number that looks plausible in a table.
            floor = 0.4 * (value if kind == "pl" else float(default_pl))
            if avg_p < floor:
                print(f"# ABORTING: {label} averaged {avg_p:.1f}W, below the "
                      f"{floor:.0f}W floor for a loaded card. The benchmark is "
                      f"not running on the card being measured.", flush=True)
                return 1

            row = dict(kind=kind, value=value, setting=label, tflops=round(tflops, 2),
                       avg_watts=round(avg_p, 1), max_temp=max_t, sm_mhz=sm,
                       throttle=",".join(thr) or "-")
            rows.append(row)
            print(f"  {label:<14} {tflops:6.2f} TFLOPS  {avg_p:6.1f}W avg  "
                  f"{max_t:4.0f}C  {sm:>5}MHz  {row['throttle']}", flush=True)
            if args.out:
                with open(args.out, "a") as fh:
                    fh.write(json.dumps(row) + "\n")
    finally:
        smi(["-i", str(args.gpu), "-pl", str(int(float(default_pl)))], sudo=True)
        smi(["-i", str(args.gpu), "-rgc"], sudo=True)
        print(f"\n# restored: power limit "
              f"{query(args.gpu, ['power.limit'])[0]} W, clocks unlocked", flush=True)

    pl_rows = [r for r in rows if r["kind"] == "pl"]
    if pl_rows:
        base = max(pl_rows, key=lambda r: r["value"])
        print(f"\n# vs {base['setting']} ({base['tflops']} TFLOPS):", flush=True)
        for r in rows:
            delta = 100 * (r["tflops"] / base["tflops"] - 1)
            eff = (r["tflops"] / r["avg_watts"] * 1000) if r["avg_watts"] else 0
            print(f"  {r['setting']:<14} {r['tflops']:6.2f} TFLOPS  {delta:+5.1f}%  "
                  f"{r['avg_watts']:6.1f}W  {r['max_temp']:4.0f}C  {eff:5.1f} GFLOPS/W",
                  flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
