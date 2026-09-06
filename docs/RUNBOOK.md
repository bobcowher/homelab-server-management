# Lab Server Runbook

How to run, change, and repair `lab` — the two-GPU inference and training box — and how to add new models to it.

**This file is the canonical copy.** A formatted version is published at
<https://claude.ai/code/artifact/54148b8a-a0a5-4ee5-9319-af427f12abae>
for convenience; if the two ever disagree, this one is right.

| | |
|---|---|
| **Host** | `lab.local` — the LAN is DHCP, never pin the IP |
| **OS** | Ubuntu 26.04.1 LTS (`resolute`), kernel 7.0.0-31 |
| **GPUs** | RTX 3060 12GB (device 0) + RTX 3090 24GB (device 1) |
| **Disk** | 1.8T root, LVM, single NVMe, **no backups** |
| **Design** | [`docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md`](superpowers/specs/2026-09-04-lab-server-ansible-design.md) |

---

## Contents

1. [Everyday commands](#everyday-commands)
2. [Where to change what](#where-to-change-what)
3. [What runs where](#what-runs-where)
4. [Adding a model](#adding-a-model)
5. [Routine changes](#routine-changes)
6. [Upgrades and holds](#upgrades-and-holds)
7. [When it breaks](#when-it-breaks)
8. [Handle with care](#handle-with-care)
9. [Known gaps](#known-gaps)

---

## Everyday commands

Run from the repo root. Sudo on `lab` is passwordless for `robertcowher`, so no `--ask-become-pass`.

### Apply the whole configuration

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml
```

Applies every role, then automatically runs the full verification. A healthy run ends `changed=0`. Anything reporting `changed` on a second consecutive run is a bug — a role doing work it already did.

### Check health without changing anything

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```

This is the "is everything actually up?" test. It reads the machine back and asserts ~70 facts: service states, listening sockets, GPU visibility inside a container, firewall rule *ordering*, file ownership, the beekeeper redirect. It changes nothing.

> **Why two playbooks.** `changed=0` proves Ansible didn't redo work. It does *not* prove the host is correct. The verify playbook never trusts Ansible's own reporting — it queries the machine. That distinction caught four real bugs during the build that a green apply had hidden.

### Work on one role

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml   --tags webstack
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags webstack
```

Tags: `base users storage nvidia docker firewall conda tools llama_swap webstack beekeeper`

### Syntax check, no host needed

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --syntax-check
```

---

## Where to change what

Roles are a shared library at the top level; `hosts/lab/` composes them for this one machine. A second lab server gets its own `hosts/<name>/` and picks the roles it wants — a box with AMD GPUs gets a new `amd_gpu` role *instead of* `nvidia`, rather than a vendor branch inside it.

| Path | Holds | Edit when |
|---|---|---|
| `inventory/hosts.yml` | How to reach the host — `lab.local`, not an IP | Adding a machine |
| `inventory/group_vars/all.yml` | Fleet invariants: UID/GID map, LAN subnet | Almost never |
| `hosts/lab/vars.yml` | Host specifics: driver branch, versions, tool lists, conda envs, timezone | Most changes start here |
| `hosts/lab/main.yml` | Which roles this host runs, in order | Adding/removing a role |
| `hosts/lab/verify.yml` | End-state assertions, tagged per role | Adding something worth checking |
| `roles/<name>/` | Reusable logic, no host specifics | Changing *how* something is done |

> ⚠️ **Never drift the numeric IDs.** `ml=3000`, `robertcowher=1000`, `beekeeper=2001`, `llm=2002`, `files=2003`. Pinned so `/data` ownership survives a rebuild. Restoring `/data` onto a host where they differ silently produces wrong ownership, and nothing tells you until something can't read its own files. They live in exactly one file for that reason.

> ⚠️ **The LAN is DHCP — never pin an IP.** Addresses change on lease renewal. The inventory uses `lab.local`, which avahi keeps pointed at the right machine. A literal IP fails in the worst way: plays fail to connect, and every URL assertion in `verify.yml` would end up testing whatever machine later took that address. `lan_subnet` is the one address-shaped constant — a subnet is stable where a host address is not.

> ⚠️ **`group_vars` must sit beside the inventory.** A repo-root `group_vars/` is **not** loaded — Ansible looks beside the inventory file or beside the playbook, and `hosts/lab/main.yml` is neither. Move it and every UID silently becomes undefined, with no error.

---

## What runs where

Only four things are reachable from the LAN. Everything containerized binds loopback and is reached through Caddy.

| Service | Bind | Reach it at | Managed by |
|---|---|---|---|
| SSH | **LAN** `:22` | `ssh robertcowher@lab.local` | system |
| Caddy | **LAN** `:80` | `http://lab.local/` | `webstack` |
| llama-swap | **LAN** `:8080` | `http://lab.local:8080/` | `llama-swap.service` |
| Beekeeper | **LAN** `:5000` | `http://lab.local:5000/` | `beekeeper.service` |
| Open WebUI | local `127.0.0.1:3000` | `http://lab.local/` | `webstack` |
| File Browser | local `127.0.0.1:8081` | `http://lab.local/files/` | `webstack` |
| node-exporter | local `127.0.0.1:9100` | local scrape only | `webstack` |
| DCGM exporter | local `127.0.0.1:9400` | local scrape only | `webstack` |

### Why Caddy exists

**ufw cannot filter Docker published ports.** Docker writes into the `nat` PREROUTING and FORWARD chains, evaluated before ufw's INPUT rules — a container published with `-p 3000:3000` is LAN-reachable even under default-deny. So containers bind loopback, Caddy is the one exposed container, and container traffic is filtered in the `DOCKER-USER` chain instead.

Caddy is a security control here, not a convenience. To confirm it works, run this **from another machine** — from lab itself it proves nothing:

```bash
curl -m5 http://lab.local/        # 200 — Caddy answers
curl -m5 http://lab.local:3000/   # must fail to connect
```

### Beekeeper is the deliberate exception

It sits directly on `:5000` rather than behind a Caddy subpath. It has no `ProxyFix`, `SCRIPT_NAME`, or `APPLICATION_ROOT` handling and its templates hardcode absolute paths like `/admin`. Proxied under a subpath it would break — and break *silently into Open WebUI*, whose routes match the escaped paths. `lab.local/beekeeper` is a 302 to port 5000, not a proxy.

---

## Adding a model

Models are declared in **`hosts/lab/vars.yml`** under `llama_models` — not in the template, which only renders them. llama-swap starts a backend on demand, proxies to it, and shuts it down after its TTL, so many models can be configured while only the one in use holds VRAM.

### Know your GPUs before you place a model

| Index | Card | VRAM | PCI |
|---|---|---|---|
| `0` | RTX 3060 | 12 GB | `04:00.0` |
| `1` | RTX 3090 | 24 GB | `0A:00.0` |

**Index 0 is the smaller card**, and that one numbering holds everywhere — `gpus`, `tensor_split`, and `nvidia-smi` all agree.

> ⚠️ That agreement is *manufactured*, not natural. Left alone, CUDA orders devices fastest-first and calls the **3090** index 0 — the exact reverse. The role passes `-e CUDA_DEVICE_ORDER=PCI_BUS_ID` into each container to force PCI order. Remove that env var and every `tensor_split` silently inverts, quietly loading the big half of a model onto the small card. The `CUDA_DEVICE_ORDER` in the systemd unit does **not** cover this: it applies to the llama-swap process, and the model runs in a container with its own environment.

### Three placements, measured

Same prompt, same harness (`scripts/bench_model.sh`), 200 generated tokens, on the 19 GB Laguna Q4_K_M:

| Placement | VRAM | Prompt | Generation | 3090 free for RL? |
|---|---|---|---|---|
| `gpus: all` | 18012 + 8747 | 409 tok/s | **150 tok/s** | no |
| `gpus: device=1` + `n_cpu_moe: 20` | 16616 | 136 tok/s | 83 tok/s | no |
| `gpus: device=0`, 16k ctx | 10779 | 65 tok/s | 60 tok/s | **yes** |

Spanning both cards nearly doubles generation, because nothing has to push expert weights across PCIe into system RAM. That is the default. `-sm layer` is *pipelined*, not parallel — it buys capacity, not parallel compute, which is why the split proportions matter.

Pin to the 3060 only for a model that should sit resident and serve continuously. That is the one case where `ttl: 0` is allowed, and `verify.yml` enforces the pairing: a model may skip its eviction timer **only** if it is pinned to the small card, so nothing can ever squat on the 3090.

### 1. Get the weights

Prefer `hf:` and let llama.cpp download into the shared cache:

```yaml
hf: unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q6_K
```

Or place a file yourself, for weights you already have locally:

```bash
# /data/models is group ml with setgid — new files stay group-readable
scp mymodel-q4_k_m.gguf robertcowher@lab.local:/data/models/
```

File Browser at `lab.local/files/` writes as the `files` user into the same tree.

### 2. Declare it

Add an entry to `llama_models` in `hosts/lab/vars.yml`. `${PORT}` is llama-swap's macro — it assigns a free loopback port per backend, so backends are never LAN-exposed.

```yaml
  - name: my-model
    hf: some-user/Some-Model-GGUF:Q6_K   # or: file: my-model-q4_k_m.gguf
    gpus: all                            # all | device=0 (3060) | device=1 (3090)
    split_mode: layer
    tensor_split: "12,24"                # 3060,3090 — same order as nvidia-smi
    ctx: 65536
    threads: 16
    args: "--jinja -fa on --cache-type-k q8_0 --cache-type-v q8_0"
```

`--jinja` is required for anything doing tool calls: it makes llama.cpp use the model's real chat template.

### 3. Apply and confirm

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags llama_swap
```

The config installs with `validate: llama-swap -config %s -validate`, so a malformed config is rejected *before* it reaches disk and the running service is never left broken. By hand:

```bash
ssh robertcowher@lab.local \
  '/usr/local/bin/llama-swap -config /etc/llama-swap/config.yaml -validate'
# config is valid: 1 model(s), 0 peer(s)
```

### Using it from the web UI

Open WebUI at `http://lab.local/` is already pointed at llama-swap's OpenAI-compatible endpoint (`OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1`, in the compose file). New models appear in its dropdown once llama-swap knows about them. If one doesn't show, refresh the model list under **Settings → Connections**.

> ⚠️ **Container → host traffic needs its own firewall rule.** Open WebUI reaches llama-swap over the Docker bridge, so its packets arrive from `172.16.0.0/12`, *not* the LAN subnet. The `lan_subnet` ufw rule does not cover them and default-deny drops the traffic — the symptom is an empty model dropdown, **not** an error. There is a separate ufw rule for the bridge range. Any other native service containers must reach needs the same treatment.

### Using it from a harness or agent

llama-swap speaks the OpenAI API, so anything accepting a custom base URL works. There is no API key — it's LAN-only and unauthenticated, so pass any non-empty placeholder where a client demands one.

```bash
export OPENAI_BASE_URL="http://lab.local:8080/v1"
export OPENAI_API_KEY="none"

# what does the server actually offer?
curl -s http://lab.local:8080/v1/models | jq '.data[].id'

# a real completion
curl -s http://lab.local:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-coder","messages":[{"role":"user","content":"hi"}]}' \
  | jq -r '.choices[0].message.content'
```

The first request to an unloaded model blocks while llama-swap starts the backend — that's the swap working, not a hang. `healthCheckTimeout` (currently 900s) bounds the wait; raise it for large models on a cold cache.

Prefer `lab.local:8080` over a raw IP in anything you keep. mDNS resolves exactly one name — `webui.lab.local` and friends will **not** resolve without extra avahi configuration, which is why all web routing is path-based on the single host.

### Freeing the GPU for a training run

A loaded model holds its VRAM until it is unloaded. CUDA allocations are not preemptible: if a
training run asks for memory llama.cpp is holding, the **training run** is what fails, with
`CUDA_ERROR_OUT_OF_MEMORY`. llama.cpp is never asked to yield and never learns anything wanted the
memory. Measured with laguna resident on the 3090 (16634 MiB held): a 20 GiB request failed, and
five seconds later the model was still loaded and holding every byte.

This matters more now that the default placement spans **both** cards — a loaded model puts weights
on the 3090 *and* the 3060, so it is the whole box that is occupied, not one card.

Before a large run, free the card by hand:

```bash
curl -s http://lab.local:8080/unload    # drops loaded models; VRAM returns to ~1 MiB
nvidia-smi --query-gpu=index,memory.used --format=csv
```

Left alone, a model releases itself after its `ttl` (currently 900s idle). That is the intended
default: this is an RL box that occasionally serves models, so the automatic path is to wait it
out, and the command above is for when you would rather not.

The failure is deferred, which is the part that bites. PyTorch grows its allocator pool on demand,
so a run can start inside the leftover VRAM, train for an hour, and then die on a batch that
spikes — or when llama-swap loads a *larger* model mid-run. If a run must not fail, unload first
rather than trusting the headroom.

To re-measure any of this, `scripts/vram_probe.py` asks for a given amount of VRAM on a given card
and reports what the driver says. It uses `libcuda` directly, so it needs no torch — but it has to
run on the host with the GPUs:

```bash
scp scripts/vram_probe.py lab:/tmp/
ssh lab '/opt/conda/envs/py312/bin/python /tmp/vram_probe.py 1 20'   # device 1 = the 3090, 20 GiB
```

Exit code 2 means out of memory, 1 means any other CUDA failure.

---

## Routine changes

### Add a command-line tool

One line in `hosts/lab/vars.yml`, never a role edit:

```yaml
tools_apt:  [htop, nvtop, iotop, ncdu, tree, ripgrep, ..., your-tool]
tools_pipx: [nvitop, your-python-tool]
```

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags tools
```

Use `tools_pipx` for anything from PyPI — Ubuntu 26.04 enforces PEP 668, so a system-wide `pip install` fails outright.

### Add a shared conda environment

```yaml
conda_envs:
  - { name: beekeeper, python: "3.12" }
  - { name: py312,     python: "3.12" }
  - { name: yourenv,   python: "3.12" }
```

Shared environments live in `/opt/conda/envs` and are **read-only** — deliberately, so nobody can mutate an environment a running service depends on. To install into one, clone it first; the clone lands in your home directory and is writable:

```bash
conda create -n mywork --clone py312
conda activate mywork
pip install whatever
```

`base` does not auto-activate. That's intentional — a base environment silently prepended to every shell's `PATH` is how the wrong Python ends up running a service.

### Open a new port to the LAN

For a **native** service, add the port to the loop in `roles/firewall/tasks/main.yml`. For a **container**, ufw won't help — add a rule to `roles/firewall/templates/docker-user-rules.sh.j2` above the DROP line and publish the container on the LAN. Prefer routing it through Caddy instead.

---

## Upgrades and holds

Sixteen packages are held: everything matching `nvidia*`, `libnvidia*`, `docker-ce*`, `containerd*`. Unattended-upgrades is scoped to security origins only.

Both exist for the same reason: an automatic driver bump moves the userspace libraries out from under the loaded kernel module and breaks every GPU container, with no warning until something tries to use a GPU. The distro default allowed the full release pocket, which would have done exactly that.

```bash
ssh robertcowher@lab.local 'apt-mark showhold'
```

### Deliberately upgrade the driver

1. Check what apt intends first — **if any line starts with `Remv`, stop**:
   ```bash
   sudo apt-get install --dry-run nvidia-utils-<branch> | grep -E '^(Remv|Inst)'
   ```
2. Update `nvidia_driver_branch` in `hosts/lab/vars.yml`.
3. Unhold, upgrade, **reboot** — the kernel module and userspace libraries must match, and a running kernel keeps the old module until restart.
4. Re-run the playbook to reapply holds, then verify GPUs still reach containers:
   ```bash
   ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags nvidia,docker
   ```

### Update llama-swap

Set `llama_swap_version` and `llama_swap_sha256` in `hosts/lab/vars.yml`. Get the checksum from the release's own file — the download is verified against it before install:

```bash
curl -sL https://github.com/mostlygeek/llama-swap/releases/download/v<N>/llama-swap_<N>_checksums.txt \
  | grep linux_amd64
```

---

## When it breaks

Start here. The verify playbook usually names the problem faster than reading logs.

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```

| Symptom | Likely cause | Check |
|---|---|---|
| SSH: *"System is booting up. Unprivileged users are not permitted to log in yet"* | `/run/nologin` still present — `systemd-user-sessions` queued behind a slow `network-online.target`. **Not a lockout; it clears.** Stop retrying: rapid attempts trip `MaxStartups` and add confusing `kex_exchange_identification` resets on top. | `systemd-analyze blame \| head` |
| Boot takes minutes | `systemd-networkd-wait-online` waiting on a NIC with no cable | `systemd-analyze critical-chain systemd-user-sessions.service` |
| Containers can't reach the internet | conntrack RETURN in `DOCKER-USER` missing or ordered after the DROP. Presents as silent hangs, no error. | `sudo iptables -S DOCKER-USER` |
| Open WebUI model dropdown is empty | Container → host traffic blocked; the bridge-range ufw rule is missing | `sudo docker exec webstack-open-webui-1 curl -s -o /dev/null -w '%{http_code}' http://host.docker.internal:8080/v1/models` |
| A container is LAN-reachable that shouldn't be | It's publishing to `0.0.0.0`. ufw will not save you. | `ss -ltn` |
| Caddy returns 502 | Backend still starting, or Caddyfile points at `127.0.0.1` instead of a compose service name | `sudo docker ps` |
| `nvidia-smi` works, containers see no GPU | Container toolkit or the nvidia runtime in `daemon.json` | `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L` |
| Driver/library version mismatch | Userspace packages moved without a reboot | `cat /proc/driver/nvidia/version` |
| llama-swap won't start | Bad model config — a wrong path fails at load, not at validate | `journalctl -u llama-swap -n 50` |
| nvitop shows no process owners | Not running as root; unprivileged it masks `beekeeper` and `llm` processes | `sudo nvitop` |

```bash
ssh robertcowher@lab.local 'sudo docker ps --format "{{.Names}}: {{.Status}}"'
ssh robertcowher@lab.local 'sudo docker compose -f /etc/docker/compose/webstack/docker-compose.yml logs --tail 50'
ssh robertcowher@lab.local 'systemctl status llama-swap beekeeper docker-compose@webstack docker-user-rules'
ssh robertcowher@lab.local 'sudo nvitop -1'

# restart the web stack
ssh robertcowher@lab.local 'sudo systemctl restart docker-compose@webstack'
```

---

### The empty second NIC

This box has two network ports and one cable. `systemd-networkd-wait-online`
waits for **all** managed links by default, and netplan generates a drop-in
whose first `ExecStart` has no `--any` — so it required both links to come up.
The empty port sits at `no-carrier` forever, and the unit burned its full 120s
timeout on every boot.

That is not just slow. `docker.service` and `llama-swap.service` both
`Wants=network-online.target`, which pulls the waiter into the boot;
`remote-fs.target` queues behind it, and `systemd-user-sessions.service` —
which deletes `/run/nologin` — queues behind that. The result was a two-minute
window after every boot where SSH answered but refused every non-root login.
On a headless machine that reads as a lockout.

The `base` role installs a drop-in scoping the wait to `wan_interface` with
`--any` and a 30s cap. Userspace boot went from **2min 6s to 10.6s**, and
`verify.yml` now asserts both the scoping and that `/run/nologin` is absent.

**If you ever plug in the second port**, nothing breaks — `--any` is satisfied
by the first link that comes up.

---

## Handle with care

Five operations can take the machine away from you. Each is guarded — the guards are the point, don't remove them.

**`ufw enable`** — Port 22 is allowed by a task that runs *before* the enable task. Reordering them disconnects you from a headless machine permanently. New rules go above the enable.

**Anything under `/etc/sudoers.d`** — A parse error breaks `sudo` for **every** user, including yours, and the playbook has no other route to root. Every sudoers file installs with `validate: /usr/sbin/visudo -cf %s`, which refuses to write a file that doesn't parse. Never drop that. *(It has already earned its keep once: it caught a wildcard the local sudo rejects.)*

**The LVM extend** — Growing a mounted ext4 filesystem is routine and one-way. Already run; root fills the volume group and `VFree` is 0, so the task is now a no-op. There are no backups, so a bad extend means a rebuild.

**`sshd_config`** — Installed with `validate: /usr/sbin/sshd -t -f %s`, and the handler *reloads* rather than restarts so existing sessions survive. After any change, open a genuinely new connection before trusting it — an existing multiplexed session will happily mask a broken config:
```bash
ssh -o ControlPath=none robertcowher@lab.local true
```

**Driver packages** — Dry-run apt before installing anything `nvidia-*`. A userspace/kernel-module mismatch breaks every GPU workload until reboot.

---

## Known gaps

### 🔴 No backups — the largest outstanding risk

`restic` is installed and deliberately unconfigured: no repos, timers, or credentials. `/data` sits on root, on a single NVMe, with no redundancy. A disk failure loses every model, dataset, and Beekeeper's training history. The fixed UIDs mean a restore would be *correct*; there is simply nothing to restore from.

### 🟠 Beekeeper's sudo grant is wider than intended

Beekeeper is deployed and running. But `setup.sh` installs its unit with `sudo cp "$(mktemp)" …`, and this `sudo` rejects wildcards in command arguments, so the grant could not be scoped to a source path — it is an unrestricted `/usr/bin/cp`. The ceiling is unchanged in kind (anyone who can write a systemd unit can already run code as root) but the path is wider than it should be.

Fix is upstream and small — have `setup.sh` write the unit with:
```bash
sudo tee "$SERVICE_FILE" < "$TEMP_SERVICE"
```
which leaves a fixed argument sudoers can name exactly.

### 🟠 Beekeeper's state lives inside its checkout

`data/beekeeper.db`, `projects/`, `.secret_key` and `config.properties` all sit in the git working tree, which `deploy.sh` subjects to `git reset --hard` and `rm -rf venv`. It survives only because those paths are gitignored — a stray `git clean -xdf` destroys the training history.

### 🟠 `deploy.sh` targets the wrong path

It points at `/home/bobcowher/beekeeper`; this host installs to `/home/beekeeper/beekeeper`. Reconcile before relying on it.

### 🟡 Inference and training contend for VRAM with no arbiter

llama-swap arbitrates its own models against each other and knows nothing about training jobs;
training jobs know nothing about it. Nothing coordinates the two — the manual path is
[Freeing the GPU for a training run](#freeing-the-gpu-for-a-training-run).

Automating it was considered and **deliberately deferred**. The obvious trigger, a Beekeeper
job-start hook, would push a lab-specific VRAM policy into a public project that every other user
would inherit; and "always unload before training" is not always the wanted behavior, since running
a model and a training job side by side is sometimes the point. Revisit if a real run is ever lost
to this. If it is automated, it belongs in a local job-launch wrapper, not upstream in Beekeeper.

### 🟡 Tailscale, TLS, and real hostnames

Excluded from this iteration. A tunnel egresses *from* the box, so it needs no inbound firewall change — the LAN-only default-deny stays correct. Real hostnames and TLS behind Caddy additionally require subpath support in Beekeeper, which belongs in that repo.
