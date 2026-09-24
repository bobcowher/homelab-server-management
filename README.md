# Lab server

This repository configures `lab`, an Ubuntu 26.04 machine used for local LLM
inference and reinforcement-learning work. It has an RTX 3060 (12 GB) and an
RTX 3090 (24 GB), a single 1.8 TB NVMe, and is reached on the LAN as
`lab.local`.

Ansible owns the host configuration: users, storage, GPU plumbing, Docker,
firewall rules, Python environments, services, and overnight power management.
The aim is to make the machine rebuildable without having to remember the
manual setup.

## What is deployed

The LLM path looks like this:

```text
Open WebUI, coding agents, or API clients
                  |
                  | OpenAI-compatible API
                  v
          llama-swap on :8080
                  |
                  | starts and stops backends on demand
                  v
        CUDA llama.cpp containers
                  |
                  v
          GGUF files in /data/models
```

`llama-swap` is a native systemd service. It starts a llama.cpp container when
a model is requested, proxies traffic to it, and stops it after its idle TTL.
Large models can use both GPUs; the smaller family model is pinned to the 3060
so the 3090 normally remains available for training. There is no Ollama, vLLM,
or host CUDA toolkit.

The web stack is a Docker Compose project with six containers:

- Caddy is the only LAN-exposed container.
- Open WebUI provides the browser chat interface.
- SearXNG provides private web search to Open WebUI.
- File Browser exposes `/data` through the web UI.
- node_exporter and DCGM exporter provide local-only host and GPU metrics.

Beekeeper runs natively as its own user and manages training jobs. Its jobs use
EGL for headless MuJoCo rendering and may start TensorBoard instances on ports
6006 through 6016.

The useful endpoints are:

| Service | Address |
|---|---|
| Open WebUI | `http://lab.local/` |
| File Browser | `http://lab.local/files/` |
| llama-swap API and UI | `http://lab.local:8080/` |
| OpenAI-compatible API | `http://lab.local:8080/v1` |
| Beekeeper | `http://lab.local:5000/` |
| SSH | `ssh robertcowher@lab.local` |

Open WebUI and File Browser sit behind Caddy. Beekeeper is deliberately served
on port 5000 because it does not support being mounted under a URL prefix.
SearXNG and the metrics exporters are not exposed to the LAN.

Most persistent application data and all model weights live under `/data`.
The directory is on the root LVM filesystem, not a separate disk or mount.
Beekeeper currently keeps its state inside its checkout, and Caddy uses Docker
named volumes. Fixed UIDs and GIDs keep `/data` ownership stable across
rebuilds.

## Deploying the server

Run Ansible from this repository on a machine that can SSH to `lab.local`.
The target must already have Ubuntu 26.04, working key-based SSH, and a
compatible NVIDIA driver. The NVIDIA role installs the matching utilities,
EGL libraries, and container toolkit; it does not bootstrap the kernel driver
on a bare machine.

Install the required Ansible collections once:

```bash
ansible-galaxy collection install -r requirements.yml
```

Check that the inventory resolves and SSH works:

```bash
ansible -i inventory/hosts.yml lab -m ping
```

Check the playbook without contacting or changing the host:

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --syntax-check
```

Apply the whole configuration:

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml
```

The main playbook automatically runs the verification playbook after all roles
finish. Run it a second time when changing infrastructure; a healthy second run
should end with `changed=0`.

To check the machine without changing it:

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```

To work on one part of the system, use its tag:

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags webstack
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags webstack
```

Available tags are `base`, `users`, `storage`, `nvidia`, `docker`, `firewall`,
`conda`, `tools`, `llama_swap`, `webstack`, `beekeeper`, and `power`.

## Repository scripts

The scripts under `scripts/` are operational tools, not Ansible entry points.
Unless noted otherwise, run them on `lab`, where the GPUs, Docker daemon,
models, and services exist. Copy the repository there or copy the individual
script you need.

### Fetch a model

`fetch_model.sh` downloads one GGUF file from Hugging Face into `/data/models`.
It uses parallel range requests, resumes partial downloads, and refuses to
accept a model unless Hugging Face publishes a SHA-256 hash that matches the
download.

```bash
bash scripts/fetch_model.sh \
  google/gemma-4-12B-it-qat-q4_0-gguf \
  gemma-4-12b-it-qat-q4_0.gguf
```

An optional third argument changes the destination directory. Downloading a
file does not add it to the server: declare the model under `llama_models` in
`hosts/lab/vars.yml`, then apply the `llama_swap` role.

### Benchmark a configured model

`bench_swap.sh` sends a fixed prompt through the running llama-swap service and
prints GPU memory use plus prompt and generation throughput:

```bash
bash scripts/bench_swap.sh qwen3-coder
```

This is the normal benchmark to use when comparing models as clients actually
see them.

### Experiment with llama.cpp placement

`bench_model.sh` bypasses llama-swap and launches a temporary llama.cpp
container directly. It is intended for testing GPU placement and server flags.
The script currently benchmarks the Laguna model at
`/data/models/Laguna-XS-2.1-Q4_K_M.gguf` and uses port 8099.

```bash
bash scripts/bench_model.sh both-gpus all \
  --jinja -fa on -c 65536 --threads 16

bash scripts/bench_model.sh 3090-only device=1 \
  --jinja -fa on -c 32768 --threads 16
```

The temporary container is removed when the script exits. Do not run this on a
busy training machine without checking available VRAM first.

### Check that both GPUs can actually compute

`gpu_health.py` creates a fresh CUDA context, allocates tensors, and runs a
matrix multiplication on every GPU. This is stronger than `nvidia-smi`, which
can look healthy even when new CUDA contexts fail.

Run it with a Python environment that already has PyTorch installed, normally
one of Beekeeper's project environments:

```bash
sudo -u beekeeper \
  /home/beekeeper/.conda/envs/<environment>/bin/python \
  scripts/gpu_health.py
```

### Probe available VRAM

`vram_probe.py` asks the CUDA driver to allocate a requested amount of memory.
It uses `libcuda` directly and does not require PyTorch.

```bash
# device 1 is the RTX 3090; try to allocate 20 GiB
/opt/conda/envs/py312/bin/python scripts/vram_probe.py 1 20

# hold the allocation for 30 seconds
/opt/conda/envs/py312/bin/python scripts/vram_probe.py 1 20 30
```

Exit code 2 means out of memory. Exit code 1 means another CUDA failure.

### Test the overnight idle checks

`test_idle_checks.sh` exercises branches in the shutdown decision logic that
are difficult to trigger safely, including missing sysstat data, busy
Beekeeper, manual overrides, reboot markers, and stale login sessions.

```bash
sudo bash scripts/test_idle_checks.sh
```

It runs modified temporary copies of the installed shutdown script with
`--dry-run`; it cannot power off the machine.

To inspect the real current decision without acting on it:

```bash
sudo /usr/local/sbin/lab-idle-shutdown --dry-run
```

Your SSH session will count as activity, so a hand-run check normally decides
to stay up.

## Working with models

Models are declared in `hosts/lab/vars.yml`. Each entry supplies a name, local
GGUF file or Hugging Face reference, GPU placement, context size, thread count,
and any llama.cpp arguments.

GPU numbering is fixed throughout this repository:

| Device | GPU | VRAM |
|---|---|---:|
| `device=0` | RTX 3060 | 12 GB |
| `device=1` | RTX 3090 | 24 GB |
| `all` | Both cards | 36 GB combined |

Do not add `tensor_split` or `ngl` without a measured reason. Leaving both
unset lets llama.cpp fit the model to the VRAM that is actually free when it
starts. The verification playbook currently enforces this policy.

After adding or changing a model:

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags llama_swap
curl -s http://lab.local:8080/v1/models | jq '.data[].id'
```

The first request to an unloaded model waits while its backend starts. Idle
models unload after 900 seconds by default.

Inference and training do not share a scheduler. If a model already occupies
VRAM, a training job can fail later with an out-of-memory error. Before a large
training run, unload inference explicitly:

```bash
curl -s http://lab.local:8080/unload
nvidia-smi --query-gpu=index,memory.used --format=csv
```

To call the server from an OpenAI-compatible client:

```bash
export OPENAI_BASE_URL=http://lab.local:8080/v1
export OPENAI_API_KEY=none
```

The API is trusted-LAN only and has no API-key authentication.

## Where to make changes

| Path | Purpose |
|---|---|
| `inventory/hosts.yml` | How Ansible reaches the machine |
| `inventory/group_vars/all.yml` | Fleet-wide UID, GID, and LAN invariants |
| `hosts/lab/vars.yml` | Host-specific versions, models, tools, and settings |
| `hosts/lab/main.yml` | Roles applied to this host and their order |
| `hosts/lab/verify.yml` | Read-only end-state checks |
| `roles/` | Reusable installation and configuration logic |
| `scripts/` | Model, GPU, benchmark, and shutdown test utilities |

Most routine changes begin in `hosts/lab/vars.yml`:

- Add apt packages under `tools_apt`.
- Add Python command-line tools under `tools_pipx`.
- Add shared Python environments under `conda_envs`.
- Add or modify inference models under `llama_models`.
- Adjust overnight shutdown behavior with the `power_*` variables.

The numeric UIDs and GID in `inventory/group_vars/all.yml` are part of the
on-disk data format. Do not change them without migrating ownership under
`/data`.

## Service and data management

Useful status commands:

```bash
systemctl status llama-swap beekeeper docker-compose@webstack docker-user-rules
sudo docker ps --format '{{.Names}}: {{.Status}}'
sudo nvitop -1
```

Web stack logs and restart:

```bash
sudo docker compose \
  -f /etc/docker/compose/webstack/docker-compose.yml \
  logs --tail 100

sudo systemctl restart docker-compose@webstack
```

llama-swap and power-management logs:

```bash
journalctl -u llama-swap -n 100
journalctl -u lab-idle-shutdown -n 100
```

To prevent tonight's automatic power-off:

```bash
sudo touch /run/lab-no-suspend
```

The override disappears on the next boot. The machine checks hourly from
midnight through 08:00 and powers off once it has been idle for the preceding
hour. It stays off until someone presses the power button.

## Security and maintenance notes

- SSH uses keys only; root login and X11 forwarding are disabled.
- UFW protects native services. Docker-published ports are protected
  separately through the `DOCKER-USER` chain.
- Caddy is the only container allowed to accept LAN traffic directly.
- `robertcowher` and `llm` are in the Docker group, which is root-equivalent.
- Beekeeper has a narrow-looking but effectively root-capable sudo path because
  its upstream installer owns the systemd unit.
- NVIDIA and Docker packages are held to prevent unattended version mismatches.
- Automated package upgrades are masked and must be run deliberately.
- Services use plain HTTP. This deployment assumes a trusted LAN.

Be careful when changing the firewall, SSH configuration, sudoers files, LVM,
or NVIDIA packages. Those are the changes most capable of making the machine
unreachable or breaking every GPU workload. The roles validate SSH, sudoers,
and llama-swap configuration before installing them; keep those checks in
place.

## Known limitations

The important ones are:

- There are no backups. Restic is installed but has no repository, credentials,
  or timer. `/data` is on one NVMe with no redundancy.
- Container images and several tools use floating tags or branches, so this is
  configuration-reproducible rather than bit-for-bit reproducible.
- Beekeeper keeps important state inside its Git checkout.
- Beekeeper's `deploy.sh` still refers to a different checkout path.
- Inference and training can contend for VRAM.
- Tailscale, TLS, Prometheus, and Grafana are not installed.

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for troubleshooting, measured model
performance, upgrade procedures, and the reasoning behind the less obvious
decisions. The original design is in
[docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md](docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md).
The implementation plan under `docs/superpowers/plans/` is construction
history. `requirements.md` is the original reference sheet and is not the
source of truth where it differs from the roles, host variables, or runbook.
