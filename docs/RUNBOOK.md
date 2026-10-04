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
5. [Web search](#web-search)
6. [bobgpt](#bobgpt)
7. [Routine changes](#routine-changes)
8. [Overnight power saving](#overnight-power-saving)
9. [Upgrades and holds](#upgrades-and-holds)
10. [When it breaks](#when-it-breaks)
11. [Sensors and memory faults](#sensors-and-memory-faults)
12. [Handle with care](#handle-with-care)
13. [Known gaps](#known-gaps)

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

### Let llama.cpp size the model — do not hand-tune it

**Set neither `tensor_split` nor `ngl`.** `verify.yml` fails the run if you do. llama.cpp's `--fit` (on by default) reads *free* VRAM at load time and sizes the model to match, which a static config cannot do — it cannot know what else is already resident.

This is not a small effect, and it is not what intuition predicts:

| Placement | VRAM | Prompt | Generation |
|---|---|---|---|
| `--fit`, resident model holding the 3060 | 2.5 GB + 23 GB | 443 tok/s | **160 tok/s** |
| hand-tuned `tensor_split: "12,24"`, 3060 empty | 8.7 GB + 18 GB | 409 tok/s | 150 tok/s |
| `device=1` (3090 only) + `n_cpu_moe: 20` | 16.6 GB | 136 tok/s | 83 tok/s |
| `device=0` (3060 only), 16k ctx | 10.8 GB | 65 tok/s | 60 tok/s |

The autotuner beat the hand-tuned split *while sharing a card with another model*. `-sm layer` is pipelined, not parallel, so the 3060 is the slow link in the chain — pushing **more** onto the small card costs generation speed rather than buying anything.

> ⚠️ `-ngl 99` silently defeats all of this. llama.cpp says so plainly and then fails to load: `common_fit_params: failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort`. That is why `ngl` is opt-in in the template rather than defaulted.

It also degrades gracefully in the case that matters. With a training job holding 18 GB of the 3090 and the family model holding the 3060, a 19 GB model still loaded — 4.4 GB on the 3090, 2.5 GB on the 3060, the rest on CPU, at 34 tok/s. **The training job was untouched.** Slower, but serving, and nothing had to be evicted.

### The current catalog, measured

Same prompt, 200 generated tokens, with Gemma resident on the 3060. Reproduce with `scripts/bench_swap.sh <model>` on the host:

| Model | Lane | Prompt | Generation | Notes |
|---|---|---|---|---|
| `laguna-xs-2.1` | swapping | 443 tok/s | **163 tok/s** | Q4_K_M, general |
| `qwen3-coder` | swapping | 160 tok/s | **104 tok/s** | Q6_K, coding + tool calls |
| `gemma-4-12b` | resident | 214 tok/s | **41 tok/s** | 3060 only, text+image+audio |

Laguna and Qwen both reason before answering, and so does Gemma — a short `max_tokens` can be consumed entirely by `reasoning_content`, returning an empty `content` that looks like a failure but is not. Raise `max_tokens` or cap thinking with `--reasoning-budget`.

### Two lanes: swapping and resident

Models land in one of two llama-swap groups, chosen by the `group:` key.

| | `gpu` (default) | `resident` |
|---|---|---|
| Placement | `gpus: all` | `gpus: device=0` (3060) |
| Concurrency | one at a time | stays loaded |
| Eviction | TTL, and by each other | never |
| For | big transient models | the always-on family model |

`resident` sets `persistent: true`, which is the load-bearing flag: without it the exclusive `gpu` group unloads the family model every time you ask a big model a question. **Verified**: with Gemma resident, loading laguna left Gemma loaded and answering.

`verify.yml` enforces that a `resident` model is pinned to `device=0`. A never-evicted model on the 3090 would permanently deny the training card, which is the one thing this box must not do.

### 1. Get the weights

Use `scripts/fetch_model.sh`, which fetches in parallel and **verifies the sha256** against what Hugging Face publishes:

```bash
ssh lab
bash scripts/fetch_model.sh google/gemma-4-12B-it-qat-q4_0-gguf gemma-4-12b-it-qat-q4_0.gguf
```

> ⚠️ **Never skip the checksum.** A parallel fetch of a 24 GB model produced a file of *exactly* the right byte length whose contents were wrong. It loaded with no error and generated fluent gibberish (`告诉她-même-than淯-neck-neck-than...`). Size proves nothing; only the hash does. The script refuses to fetch anything Hugging Face does not publish a hash for.

Two reasons not to use llama.cpp's built-in `-hf` downloader: it measured 0.5–4 MB/s where parallel fetching sustains ~100 MB/s, and it does no verification you can see. Hugging Face shapes throughput per connection — one stream starts near 30 MB/s and decays to ~2 MB/s within a minute.

Weights can also be placed by hand; `/data/models` is group `ml` with setgid, so files stay readable by the `llm` and `beekeeper` users.

### 2. Declare it

Add an entry to `llama_models` in `hosts/lab/vars.yml`. `${PORT}` is llama-swap's macro — it assigns a free loopback port per backend, so backends are never LAN-exposed.

```yaml
  - name: my-model
    file: my-model-q6_k.gguf     # fetched by scripts/fetch_model.sh
    gpus: all                    # all | device=0 (3060) | device=1 (3090)
    ctx: 65536
    threads: 16
    args: "--jinja -fa on --cache-type-k q8_0 --cache-type-v q8_0"
```

For an always-on model on the 3060, add `group: resident` and `ttl: 0`. A multimodal model also takes `mmproj: <projector>.gguf`, which becomes `--mmproj`.

`--jinja` is required for anything doing tool calls: it makes llama.cpp use the model's real chat template.

Gemma 4 reasons before answering, which costs latency on trivial questions — 254 thinking tokens for "17 × 23", about six seconds. `--reasoning-budget N` caps it (`0` disables thinking, `-1` is unrestricted and the default). Left unrestricted for now; add it to `args` if the family model feels slow to answer simple things.

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

## Web search

Open WebUI can search the web before answering. The backend is **SearXNG**, running in the same compose project.

It publishes no ports and Caddy does not proxy it, so nothing on the LAN can query it — Open WebUI reaches it by service name at `http://searxng:8080`. Its secret key is generated on the host at `/data/searxng/secret_key` and never enters this repo, which is public.

Two settings are load-bearing and easy to lose:

- **`formats: [html, json]`** in `searxng-settings.yml.j2`. SearXNG ships HTML-only; Open WebUI's backend parses JSON. Without it every search fails with a 403.
- **`limiter: false`**. The limiter exists to stop scraping by strangers, and the only client here is Open WebUI issuing bursts of programmatic queries — exactly what it blocks. Safe only because the container is unreachable from outside the compose network.

Check it directly:

```bash
ssh lab 'docker exec webstack-open-webui-1 \
  curl -s "http://searxng:8080/search?q=test&format=json" | jq ".results | length"'
```

An engine failing is normal and not a fault — SearXNG aggregates many, and a `CAPTCHA` entry under `unresponsive_engines` (DuckDuckGo does this often) just means the others carried the query.

### ⚠️ Open WebUI settings do not come from the compose file

Most Open WebUI settings are **PersistentConfig**: the environment variable seeds the value on the *first* start only, and from then on the copy in `webui.db` wins. A compose env var can therefore say one thing while the running app does another, with nothing reporting the drift.

This is not hypothetical. A hard-coded `192.168.1.30` survived the DHCP audit inside that database, and `ENABLE_OLLAMA_API=false` silently did nothing while every page load spent ~10s waiting on an Ollama that does not exist.

Declare such settings in `roles/webstack/templates/openwebui-desired-config.json.j2`. The play forces them into the database, reports `changed` only when it writes, and restarts the container. **Changing one of these in the Open WebUI admin UI will be reverted on the next Ansible run** — that is the point, but it will surprise you if you forget.

---

## bobgpt

A from-scratch GPT served behind the same Open WebUI as everything else. The
code lives in **`github.com/bobcowher/bobgptv1`** and is owned there, not
here. This repository does deployment only: a user, a directory, a facts file,
a bootstrap clone, a unit, and the Open WebUI upstream. Nothing here names a
run, a checkpoint, a model size or a package version.

Design and rationale: `docs/superpowers/specs/2026-10-04-bobgpt-serving-design.md`.

### Turning it on

```bash
sudo systemctl start bobgpt      # it does NOT start at boot, on purpose
sudo systemctl status bobgpt
```

It is a GPU service on a box whose GPUs exist for training, so it is started
by hand and `verify.yml` asserts it stays disabled. The box powers itself off
overnight, so it is off again every morning regardless.

If it fails with `status=203/EXEC`, the repository has not supplied
`/opt/bobgpt/src/serve.sh` yet. `verify.yml` warns about this by name rather
than leaving you with systemd's error.

### The contract

Ansible publishes every host-specific fact to **`/etc/bobgpt/host.env`**. The
unit loads it with `EnvironmentFile`, and the repository's `deploy.sh` can
read the same values with `set -a; . /etc/bobgpt/host.env; set +a`.

| Variable | Value |
|---|---|
| `BOBGPT_SRC` | `/opt/bobgpt/src` — the checkout, owned `robertcowher:ml` |
| `BOBGPT_VENV` | `/opt/bobgpt/venv` — **not** created by Ansible; `deploy.sh` owns it |
| `BOBGPT_PYTHON` | the interpreter to build that venv from |
| `BOBGPT_CHECKPOINT_ROOT` | `/data/datasets/bobgptv1/checkpoints`, read-only |
| `BOBGPT_HOST` / `BOBGPT_PORT` | `0.0.0.0` / `8100` — see below |
| `BOBGPT_DEVICE` | which card |
| `BOBGPT_MAX_LOADED` | how many runs may be resident at once |
| `BOBGPT_CACHE` | the one writable path |

The repository must provide `$BOBGPT_SRC/serve.sh`, executable, serving an
OpenAI-compatible API on `$BOBGPT_HOST:$BOBGPT_PORT`. Everything else —
dependencies, uvicorn flags, logging, which checkpoints are exposed — is the
repository's business.

**`BOBGPT_PYTHON` is not a detail.** The 3.14 that ships natively has no torch
wheels, so the venv has to be built from the conda 3.12. The beekeeper role
documents the same trap.

### Updating it

`deploy.sh` in the repository owns this, and needs sudo only for the restart:

```bash
cd /opt/bobgpt/src && git pull && sudo systemctl restart bobgpt
```

Ansible clones the checkout **once** and never updates it (`update: false`),
so a pull or a branch switch is never reverted by a playbook run. Change the
branch on the box, not in `hosts/lab/vars.yml`.

### Why it binds 0.0.0.0 and is still private

Open WebUI is a container. It reaches host services through
`host.docker.internal`, which `host-gateway` resolves to the **Docker bridge
gateway** (`172.17.0.1`) — not the host's loopback. **A service bound to
`127.0.0.1` is unreachable from it.** llama-swap works precisely because it
binds all interfaces too.

ufw default-denies incoming, and the firewall role allows `8100` from **two**
sources: `docker_bridge_subnet`, so Open WebUI can reach it, and
`lan_subnet`, so you can `curl` it from the desktop while iterating.

**The Docker rule is not redundant, and it is the one that looks it.** Because
the port is open to the LAN, it is easy to conclude the `172.16.0.0/12` rule
is covered by the `192.168.1.0/24` one and remove it. It is not: container
traffic arrives from a bridge address, which `lan_subnet` does not match.
Delete it and the model dropdown breaks while every hand test from the desktop
still passes. `verify.yml` asserts it for that reason.

Verified by experiment on 2026-10-04: a listener on `0.0.0.0:8100` answers
`200` both from inside the `open-webui` container and from the desktop. Before
the Docker rule existed the container connection **timed out** regardless of
bind address, which reads like a dead service rather than a blocked port —
worth remembering the next time something on the host is unreachable from a
container.

### What protects the training checkpoints

**POSIX does not.** The checkpoint tree is group `ml` with group write, which
is deliberate — it is how beekeeper writes runs and how you share them — and
the service user is in `ml` so it can read the weights. It can also create
files there.

`ProtectSystem=strict` on the unit is what prevents it, by making the whole
filesystem read-only except `BOBGPT_CACHE`. Verified with `systemd-run` using
the unit's exact settings: the write fails with *Read-only file system* while
the cache stays writable and the weights stay readable. `verify.yml` asserts
`ProtectSystem=strict` and that the checkpoint root never appears in
`ReadWritePaths`.

So that line in the unit is load-bearing. Do not relax it to fix a permissions
problem; fix the permissions.

### Shared dataset readability

bobgpt reads checkpoints that **beekeeper** writes: two services, two users,
one tree. The setgid bit on `/data` fixes the *group* of new files, but not
their *mode* — that comes from the writing process's umask. bobgpt could read
those checkpoints only because `beekeeper.service` happens to run
`UMask=0022`.

A **default ACL** on `storage_ml_read_dirs` makes it structural instead: when
a directory carries one, the umask is not applied to files created in it.

Proven on 2026-10-04, writing as `beekeeper` under `umask 0077`:

| | New file mode | bobgpt can read |
|---|---|---|
| With default ACL | `-rw-rw-r--` | yes |
| Without | `-rw-------` | **no** |

Without the ACL this would have failed only for runs written *after* a umask
change, while older runs kept working — a slow and confusing shape of bug.

To extend it to another shared tree, add the path to `storage_ml_read_dirs` in
`hosts/lab/vars.yml`. Keep the list short; it is for data genuinely shared
between services, not a blanket loosening.

### How it interacts with the overnight poweroff

Two settings in `hosts/lab/vars.yml`, and they are a pair:

- `power_gpu_exclude_unit: bobgpt.service` — a CUDA context lives for the life
  of a process once initialised, so a running bobgpt would appear in
  `nvidia-smi` forever and veto every shutdown. It is excluded **by cgroup**,
  not by switching the GPU check off, so a hand-run training script still
  vetoes.
- `power_bobgpt_unit: bobgpt.service` — a completion request in the last hour
  vetoes the shutdown, so the box cannot power off during a conversation.

Net effect: left running and idle, the box still powers off overnight. In use,
it does not.

### The 3060 is shared

`bobgpt_device` is `cuda:0`, the 3060 — and `gemma-4-12b` is llama-swap's
resident-lane model, pinned to the same card, where a Q4 12B at 32k context
takes most of its 12GB. A 124M model is around 0.7GB so it should still fit,
but if both are loaded and something OOMs, move `bobgpt_device` to `cuda:1` or
stop one of them. This is a variable because it is a judgement call per
session, not a constant.

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

## Overnight power saving

The box **powers itself off** overnight when nothing has used it recently, and
stays off until you press the power button. There is no scheduled wake.

The check runs hourly from 00:00 to 08:00 and shuts down on the first pass where
nothing has touched the box in the last hour. If it stays busy through the whole
window it simply stays up for the day.

### Why it powers off rather than suspending

It suspended to S3 with a 17:00 RTC wake for about two hours on 2026-09-07,
until a suspend with 8.3GB resident on the 3060 corrupted both GPUs:

```
NVRM: Xid 31, MMU Fault: ENGINE CE2_PBDMA0
NVRM: uvm encountered global fatal error 0x60, requiring os reboot to recover
NVRM: Xid 154, GPU recovery action changed to 0x2 (Node Reboot Required)
```

Both cards needed a reboot and a training run crashed on the poisoned state. A
cycle with idle GPUs was clean, so the suspect is the driver's VRAM save/restore
under `PreserveVideoMemoryAllocations=2` rather than S3 itself.

A cold boot reinitialises the driver from nothing, so that failure cannot occur.
Powering off also draws less than S3 and removes the RTC alarm, its UTC
conversion, and any dependency on a BIOS wake feature. Cold boot is 36 seconds.

Wake-on-LAN was removed with the same change: it does not wake this board from a
full power-off (tested, no response), and the box is now never in any other
state.

### Skip tonight

```bash
ssh robertcowher@lab.local 'touch /run/lab-no-suspend'
```

On `/run`, so it clears itself at the next boot. Forgetting to remove it costs
one night, not every night.

### Find out why it did or didn't shut down

```bash
ssh robertcowher@lab.local 'journalctl -u lab-idle-shutdown -n 40'
```

Every run prints each signal and its verdict, on quiet nights and busy ones
alike. To ask the same question now, without waiting for the timer:

```bash
ssh robertcowher@lab.local 'sudo /usr/local/sbin/lab-idle-shutdown --dry-run'
```

`--dry-run` never powers off. Your own SSH session counts as a login session, so
a dry-run you invoke by hand always reports at least one reason to stay up.

### What counts as "in use"

| Signal | Window |
|---|---|
| Uptime at least 3 hours | since boot |
| CPU and load peak, via `sar` | last hour |
| llama-swap inference requests | last hour |
| Beekeeper training | now |
| Processes holding a CUDA context | now |
| Login sessions, via `loginctl` | now |
| `/run/lab-no-suspend` | — |

Any single one cancels the shutdown, and anything the script cannot determine
counts as activity. The bias is deliberate: a false shutdown costs a training
run, a needless wakeful night costs pennies.

`sar` is the only signal with an hour of memory — every other one is
instantaneous and would happily power off a box whose run ended at 23:30. That
is why `sysstat` collection is not optional here; without it the script refuses
to shut down rather than guess.

**`sar` cannot see across a boot, which is why the uptime guard exists.** The
minutes a box spends powered off produce no samples, and no samples look
exactly like a quiet hour — so without the guard a machine that came up twenty
minutes ago reads as *maximally* idle. The "no history at all" check does not
catch it either: that one tests for zero rows, and twenty minutes of uptime
already yields two or three real ones, which is plenty to compute a peak of
0.00 and power off.

That is not hypothetical. On 2026-10-03 lab was switched on at 07:35:50 and
powered itself off at 08:00:06, reporting `Idle on every signal` on the
strength of two samples spanning ten minutes. The three-hour minimum is set
well above the one-hour history window on purpose: it is not padding to cover
the gap in the data, it is honouring the power button. This box has no RTC
alarm and no wake-on-LAN, so it is only ever running because someone walked
over and pressed the button — the clearest statement of intent to use it that
the machine ever receives.

Replayed against the six shutdowns on record, the guard changes exactly one of
them: the 08:00 one above. The other five all had 6 to 40 hours of uptime.

### Checking GPU health

```bash
sudo -u beekeeper /home/beekeeper/.conda/envs/<env>/bin/python scripts/gpu_health.py
```

Allocates and runs a kernel on every card. Worth knowing why it exists: during
the corruption above, `nvidia-smi` listed both GPUs with sane memory and a
running llama-server kept serving normally. Nothing visible said anything was
wrong — the failure only appeared when something asked for a *new* CUDA context.
"It booted and nvidia-smi looks fine" is not a health check.

### Changing the schedule

The `power_*` variables in `hosts/lab/vars.yml`. Set `power_shutdown_enabled:
false` to stop it without removing the role.

**Never set `Persistent=true` on the timer.** systemd would replay the overnight
runs missed while the box was off, so switching it on would power it straight
back down. `verify.yml` asserts this is off, and asserts the inverse too — that
a disabled timer is actually stopped, which caught a handler re-arming a feature
that config said was off.

---

## Upgrades and holds

Sixteen packages are held: everything matching `nvidia*`, `libnvidia*`, `docker-ce*`, `containerd*`. Unattended-upgrades is scoped to security origins only — and since the box started suspending overnight, **its timer is masked and it no longer runs on its own**. Its 06:53 slot falls inside the suspend window with `Persistent=yes`, so on resume it would have installed updates and restarted the Docker and NVIDIA stacks at the exact moment the box was wanted. Security updates are now a deliberate act:

```bash
ssh robertcowher@lab.local 'sudo unattended-upgrade -v'
```

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

### The box stops dead under load, with nothing in the journal

Traced on 2026-09-26. The journal simply ends — no `Shutting down.`, no `Journal stopped`, no panic.
That looks like a power cut or a memory fault and is neither. The cause is in the Realtek NIC's
transmit path:

```
19:03:54  WARNING: drivers/iommu/dma-iommu.c:828 at __iommu_dma_unmap+0x15b/0x170, CPU#29
            iommu_dma_unmap_phys → dma_unmap_phys → dma_unmap_page_attrs
            rtl8169_unmap_tx_skb [r8169]      <-- here
            rtl8169_poll [r8169] → __napi_poll → net_rx_action
19:04:27  first  IO_PAGE_FAULT  r8169 0000:06:00.1
19:12:10  the same WARNING again
19:15:46  145 faults later, the journal ends mid-line
```

The `WARN` at `dma-iommu.c:828` fires when the kernel is asked to unmap a DMA address the IOMMU has
no mapping for. `r8169` unmapped a TX buffer twice (or unmapped a corrupted one), the driver's TX
ring and the IOMMU's mapping table diverged, and the NIC went on DMA-ing to IOVAs that were no
longer mapped — which is what the `IO_PAGE_FAULT` stream is. Transmit then wedges and the machine
goes with it.

Check for it after any unexplained stop:

```bash
sudo journalctl --no-pager | grep -c 'dma-iommu.c:828'          # the WARN
sudo journalctl --no-pager | grep -c 'rtl8169_unmap_tx_skb'     # names the driver
sudo journalctl --no-pager | grep 'IO_PAGE_FAULT' | tail        # the consequence
```

Note `journalctl -k` implies the **current** boot, so it will report zero for an event that happened
before the last reboot. Drop `-k` to search the persistent journal.

Things that are *not* the cause, checked and ruled out:

- **Not ASPM.** `lspci -vv -s 06:00.1` already reports `LnkCtl: ASPM Disabled`, so the usual
  `pcie_aspm=off` workaround is already in effect.
- **Not memory.** Zero machine checks, and the fault addresses are a fixed repeating set of 15 IOVAs
  rather than the random scatter corruption would produce.
- **Not the GPUs.** Xid 32/31/13 appeared on both cards between 18:59 and 19:05 with a *different
  PID every time*, which is a training script crashing and relaunching, and the first IOMMU fault
  came after them. Coincident, not causal.
- **Not chronic.** Exactly two occurrences, both on that one boot, none across the other eleven. It
  is a race that needs load to hit.

**The fix was to stop using that NIC — done 2026-09-27.** The board has an Intel I211 at `enp5s0`
driven by `igb`, which has none of this, and `/etc/netplan/00-installer-config.yaml` already
configured it with `dhcp4: true`; it had been sitting at `no-carrier / configuring` waiting for a
cable. The original design targeted `enp5s0`, so moving the cable back was a return to the
documented configuration rather than a new one. **The cable now belongs in the Intel port. If it ends
up back in the Realtek, this whole failure mode comes back with it.**

Identify the port before unplugging anything, rather than counting from the case:

```bash
sudo ethtool -p enp5s0 30          # blinks that port's LED for 30s
sudo ethtool enp5s0 | grep -E 'Speed|Link detected'   # must be 1000Mb/s after the move
```

With no cable in it, `enp5s0` advertises only `10baseT/Half 10baseT/Full`, which is not what an I211
should report and looks alarming. It is an unpowered PHY; it negotiated 1000Mb/s full duplex the
moment a cable went in. A port that comes up at 10 or 100 Mbit is a real fault — move back.

What the swap fixed, all of it downstream of `wan_interface: enp5s0` finally matching reality:

- **`wait-online` stopped failing.** It had timed out for 30s on every boot while scoped to the empty
  port. `systemctl is-system-running` went `degraded` → `running`. Note the unit does not retry
  within a boot, so it stays `failed` until either a reboot or
  `systemctl restart systemd-networkd-wait-online.service`.
- **The `DOCKER-USER` DROP rule is in the traffic path again**, where it can actually catch a
  container published on `0.0.0.0` by mistake.
- **The IP went back to `192.168.1.30`.** The lease follows the MAC and the old reservation was still
  held, so the address the original design docs cite is correct again. Nothing in this repo depended
  on that — the inventory addresses `lab.local` on purpose — but a literal IP pinned in
  `/etc/hosts` elsewhere on the LAN was stale while lab sat on `.33`, and is now right again by
  accident rather than by design.

`verify.yml` asserts `wan_interface` against the live default route, so this particular drift cannot
recur silently.

---

### tmux: "missing or unsuitable terminal: xterm-ghostty"

`ssh` forwards `TERM` verbatim, so a session opened from Ghostty arrives on lab
as `TERM=xterm-ghostty`. Ubuntu's `ncurses-term` carries that terminal under the
bare name `ghostty` and ships **no `xterm-ghostty` alias**, so the lookup failed
and `tmux` refused to start. `less`, `vim` and anything else using terminfo
degraded quietly at the same time.

The `tools` role vendors Ghostty's own entry
(`roles/tools/files/terminfo/xterm-ghostty.terminfo`) and compiles it with
`tic -x -o /etc/terminfo`. **`/etc/terminfo`, not `/usr/share/terminfo`** — the
latter is dpkg-owned, so an entry compiled there survives exactly until the next
`ncurses` upgrade. Debian builds ncurses with
`TERMINFO_DIRS=/etc/terminfo:/lib/terminfo:/usr/share/terminfo`, so `/etc` is
both writable and searched first. (`/usr/local/share/terminfo` is not on that
path at all — installing there looks right and does nothing.)

Check it:

```bash
ssh robertcowher@lab.local 'TERM=xterm-ghostty tput longname'   # -> Ghostty
```

**For any other terminal**, the fix is the same shape: regenerate the source on
a machine running it and add three tasks to `roles/tools/tasks/main.yml`.

```bash
infocmp -x xterm-ghostty > roles/tools/files/terminfo/xterm-ghostty.terminfo
```

`-x` matters — the extended capabilities are where truecolor (`Tc`, `Su`) lives,
and `verify.yml` asserts they survived.

> Note what the verify does **not** do: `tmux new-session -d` exits 0 on a host
> with no entry at all, because the lookup only happens when a client attaches
> to a tty. A tmux-based check would have passed for the entire outage. The
> assertion resolves the terminfo name instead, and confirms the compiled file
> is in `/etc/terminfo`.

---

## Sensors and memory faults

### What `sensors` reports — and what it does not

`sensors` reads what the kernel's `asus_ec_sensors` driver pulls out of the board's embedded
controller: chipset, CPU, motherboard, T_Sensor and VRM temperatures, chipset fan RPM, CPU core
voltage and CPU current. `k10temp` adds the CPU die sensors and `nvme` the SSD.

Two readings look broken and are not:

- `T_Sensor: -40.0°C` — the board's optional thermistor header, with nothing plugged into it.
- `CPU: 0.00 A` and `CPU Core: 199.00 mV` — the EC exposes these registers, this BIOS doesn't
  populate them meaningfully. Use the temperatures, ignore the electrical readings.

**There is no DRAM voltage reading, and no Linux driver will give you one on this board.** Recorded
with the evidence so it doesn't get re-litigated:

- `asus_wmi_sensors` loads but registers no hwmon device — its `asus` node has a `name` and nothing
  else. That driver covers specific ROG X470/X570 boards; Pro WS X570-ACE is not one of them.
- `asus_ec_sensors` does register, reporting `board has 8 EC sensors that span 10 registers`. None
  of the eight is a DRAM rail.
- `nct6775` would reach the Nuvoton Super I/O, which *does* have a DIMM voltage input — but ACPI
  owns those I/O ports and the driver needs `acpi_enforce_resources=lax` to take them. Don't. Two
  drivers racing the embedded controller on a machine reachable only over SSH is how you get a hang
  with no console to watch it happen.
- `dmidecode -t 17` prints `Configured Voltage: 1.2 V`, and that is **not** a live measurement.
  Minimum, Maximum and Configured all read 1.2 V, which is the JEDEC nominal copied out of SPD. It
  would say 1.2 V whether or not XMP is enabled.

Settling 1.2 V vs 1.35 V requires the BIOS. Nothing on the running system knows the answer.

### Has there been a memory fault?

```bash
sudo ras-mc-ctl --errors
```

This is the persistent record, and persistence is the whole point: `dmesg` covers the current boot
only and lab powers off every night, so a machine check on Tuesday is gone by Wednesday morning.
`rasdaemon` subscribes to the kernel's MCE tracepoints and writes to sqlite under
`/var/lib/rasdaemon`. A clean machine reports `No Memory errors.` and `No MCE errors.` Ignore the
`SIGNAL events` table — rasdaemon records ordinary `SIGCHLD`s there and it is not a fault log.

**Know what this cannot see.** The DIMMs are non-ECC, and that is not a gap in the tooling, it is a
property of the hardware:

- There are **no correctable-error counters at all**. `modprobe amd64_edac` returns
  `No such device`, nothing registers under `/sys/devices/system/edac/mc`, and `edac-utils` is
  deliberately not installed because it would report nothing forever — a tool that always says
  "clean" is worse than no tool. A quietly flipped bit in non-ECC RAM is undetectable by
  construction; nothing in the machine is checking.
- What rasdaemon *can* catch is a fault severe enough to raise a machine check, plus PCIe AER and
  disk errors. Empty output means "nothing failed loudly," not "the RAM is good."

Cross-check the journal, which is persistent (`/var/log/journal`) and spans many boots:

```bash
sudo journalctl -k --no-pager | grep -iE "mce|hardware error|correctable|oops|panic|BUG:"
journalctl --list-boots    # a boot that ended well before 00:00 is the tell
```

Every normal boot ends at the nightly poweroff, so an entry ending at an odd hour is an unplanned
stop worth reading the tail of.

### Test the RAM without rebooting

Both tools test only memory the kernel will hand them, so neither covers RAM already allocated.
Size them against `free -g`, not against the installed 96 GB.

```bash
sudo memtester 8G 1                      # targeted bit patterns over a fixed allocation
sudo stressapptest -M 8192 -s 300 -W     # concurrent threads; better at finding a marginal DIMM
```

Check nothing is training first — a large run competes with Beekeeper for RAM. Neither tool opens a
login session, so neither vetoes the overnight shutdown on its own; start a long run with tonight's
shutdown skipped (see [Skip tonight](#skip-tonight)).

`memtest86+` is the only thing that tests *all* of RAM, and it is **not installed**, because it
cannot be used here: it runs as a bootloader payload, needs a GRUB menu selection and a monitor to
read the results, and lab is headless. Attach a display and install it ad hoc if it ever comes to
that.

### Suspect the configuration before the chips

`sudo dmidecode -t 17` shows four populated slots running two different kits:

| Slots | Part number | Kit |
|---|---|---|
| DIMM_A1, DIMM_B1 | `CMK64GX4M2E3200C16` | 2 × 32 GB, DDR4-3200 CL16 |
| DIMM_A2, DIMM_B2 | `CMK32GX4M2D3600C18` | 2 × 16 GB, DDR4-3600 CL18 |

96 GB total, all four dual-rank, everything running at 3200 MT/s with the 3600 kit downclocked to
match. The 5950X is Zen 3, and AMD's rated DDR4 ceiling for it depends entirely on how the slots are
populated:

| Population | Rated ceiling |
|---|---|
| 2 DIMMs, single-rank | 3200 MT/s |
| 2 DIMMs, dual-rank | 3200 MT/s |
| 4 DIMMs, single-rank | 2933 MT/s |
| **4 DIMMs, dual-rank (what's installed)** | **2667 MT/s** |

So this box runs its memory ~20% above the rated ceiling for its own population, with two kits that
were never validated against each other. That is the first thing to suspect when chasing
instability, ahead of a failing chip.

**Do not size memory from `sar` alone.** `sar` samples every 10 minutes
(`sysstat-collect.timer`, `OnCalendar=*:00/10`) on a host that reboots daily, so a training run that
allocates tens of GB for a few minutes does not appear in it at all. Reading it as a ceiling
understates real demand — a week of samples showed ~17 GB peak while `Committed_AS` in the same
window reached 31 GB. For a real number, sample at seconds:

```bash
# peak memory across a run, 5s resolution
while true; do awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^Committed_AS:/{c=$2}
  END{printf "%s used=%.1fG committed=%.1fG\n", strftime("%H:%M:%S"), (t-a)/1048576, c/1048576}' \
  /proc/meminfo; sleep 5; done
```

**The one free improvement is the clock, not the sticks.** Whatever ends up in the slots, four
dual-rank DIMMs are rated 2667 and this board runs 3200. Setting 2667 (or testing 2933) in the BIOS
costs nothing and is the only change that reduces risk without buying anything. Capacity is the
binding constraint on everything else — see the gap below for what the options actually cost.

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

Password logins are **on** (`PasswordAuthentication yes` in `roles/base/tasks/main.yml`), so a device with no key on it can still get in. `PermitRootLogin` stays `no`. Two things about this are easy to get wrong:

- **Drop-in order decides the winner, not the file you edited.** `Include /etc/ssh/sshd_config.d/*.conf` reads in lexicographic order and sshd keeps the **first** value it sees for a keyword. Ours is `10-lab.conf`; cloud-init ships `50-cloud-init.conf` with its own `PasswordAuthentication`. Renumbering ours above 50 silently hands the setting to cloud-init. Ask sshd what it actually resolved rather than reading a file:
  ```bash
  ssh robertcowher@lab.local 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin)"'
  ```
- **The flag and the account have to agree.** `PasswordAuthentication yes` on an account whose password is locked or unset looks enabled and refuses every login. `passwd -S robertcowher` must report `P` in the second field (`L` = locked, `NP` = none). The verify play asserts both the effective flag and the account state, for exactly this reason.

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

**This is smaller than it was.** Two things now blunt it without any coordination between the
systems. The always-on family model is pinned to the 3060, so the thing most likely to be resident
never touches the training card at all. And `--fit` sizes a model to whatever VRAM is *free* at
load time, so a big model started while training is running takes what is left and spills the rest
to CPU rather than failing — measured at 34 tok/s against a job holding 18 GB, with the job
untouched. What remains unhandled is the reverse order: a training run that starts **after** a
model is already resident still gets `CUDA_ERROR_OUT_OF_MEMORY`, because CUDA will not preempt.

Automating it was considered and **deliberately deferred**. The obvious trigger, a Beekeeper
job-start hook, would push a lab-specific VRAM policy into a public project that every other user
would inherit; and "always unload before training" is not always the wanted behavior, since running
a model and a training job side by side is sometimes the point. Revisit if a real run is ever lost
to this. If it is automated, it belongs in a local job-launch wrapper, not upstream in Beekeeper.

### 🟡 Nothing rate-limits SSH password attempts

Password logins are enabled and `fail2ban` is not installed, so there is no lockout after repeated
failures. The exposure is bounded rather than absent: port 22 is scoped to `192.168.1.0/24` by ufw
and nothing is forwarded from the internet, so an attacker has to already be on the LAN, and root
cannot be logged into at all. Worth fixing if lab is ever reachable from outside the LAN — which,
per the gap below, is the shape a Tailscale rollout would take.

### 🟡 Memory is non-ECC, and two mismatched kits fill all four slots

Nothing detects a silently flipped bit: non-ECC DIMMs mean no correctable-error counters exist to
read, so `rasdaemon` only ever sees a fault big enough to raise a machine check. `dmidecode -t 16`
confirms it — `Error Correction Type: None`. On top of that the 96 GB is two different Corsair kits
(a 3200 CL16 pair and a 3600 CL18 pair) filling all four dual-rank slots, which caps the rated
memory ceiling at 2667 MT/s while the board runs 3200. No errors have been recorded to date.

**ECC would fix the visibility half, and it is priced out.** This is a Pro WS board with a
Ryzen 9 5950X, so ECC UDIMM works, and with it `amd64_edac` would load, a controller would appear
under `/sys/devices/system/edac/mc`, and correctable-error counters would finally exist. But DDR4 is
end-of-life and prices have spiked: **a single 32 GB DDR4 ECC UDIMM is ~$270 as of 2026-09**, so
128 GB of ECC is ~$1080. That is not proportionate to the risk, and 64 GB of ECC is not enough
capacity to be an option. Costs actually quoted for 128 GB:

| Option | Cost | Trade |
|---|---|---|
| Two more sticks of `CMK64GX4M2E3200C16` | ~$300 | 4 × identical SKU, non-ECC |
| Matched 4 × 32 GB kit, used market | ~$700 | Validated as a set, non-ECC |
| 4 × 32 GB ECC UDIMM | ~$1080 | Error counters exist |

**The ~$300 route is the right buy**, and the reason is not that it is cheapest: the crash that
prompted this investigation was traced to the `r8169` driver, not to memory, so there is no evidence
worth $700–1080 chasing. Four sticks of one SKU removes the real defect in the current
configuration, which is two kits with *different rated timings* (3200 CL16 against 3600 CL18) that
the board has to find common settings for. Buy them as a single 2 × 32 GB kit rather than two loose
sticks so the new pair is at least matched to each other, and set 2667 in the BIOS once all four are
in.

Until ECC is affordable, the substitute for error counters is `rasdaemon` plus watching for the
signatures in [When it breaks](#when-it-breaks) — that is detection after the fact, not prevention,
and the distinction is the gap. Revisit ECC if DDR4 prices fall or the platform changes.

See [Sensors and memory faults](#sensors-and-memory-faults).

### 🟡 Tailscale, TLS, and real hostnames

Excluded from this iteration. A tunnel egresses *from* the box, so it needs no inbound firewall change — the LAN-only default-deny stays correct. Real hostnames and TLS behind Caddy additionally require subpath support in Beekeeper, which belongs in that repo.
