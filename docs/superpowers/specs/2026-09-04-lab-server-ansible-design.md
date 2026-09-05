# Lab Server Ansible — Design

**Date:** 2026-09-04
**Target:** `lab` / `192.168.1.30`
**Status:** Approved, ready for implementation planning

---

## 1. Purpose

Configure the lab server declaratively and reproducibly with Ansible, so the
host can be rebuilt without hand-reconstructing users, permissions, GPU
plumbing, or services.

`requirements.md` in the repo root describes the intended end state. It is a
reference sheet, not a build spec, and several of its claims were wrong. This
document supersedes it where they disagree. Section 9 lists the corrections.

---

## 2. Verified target facts

Probed directly on 2026-09-04, not assumed:

| Property | Value |
|---|---|
| OS | Ubuntu 26.04.1 LTS, codename `resolute` |
| Kernel | 7.0.0-31-generic |
| CPU / RAM | 32 cores / 91 GB |
| Network | `enp5s0`, `192.168.1.30/24`, hostname `lab`, avahi publishes `lab.local` |
| Storage | 1.8 TB NVMe, LVM; `ubuntu-vg/ubuntu-lv` allocated only 100 GB; ~1.7 TB unallocated |
| GPUs | RTX 3090 (24 GB) at `0a:00.0`; RTX 3060 (12 GB) at `04:00.0` |
| NVIDIA driver | `595-server-open` installed, kernel modules match running kernel; `nvidia-persistenced` running; **`nvidia-smi` absent** |
| Python | 3.14.4 only. No `python3.12` or `python3.11` in the 26.04 repos |
| Docker | Not installed |
| Conda | Not installed |
| `/data` | Does not exist |
| Access | SSH key auth works for `robertcowher`; sudo required a password at probe time |

**Superseded 2026-09-05:** `robertcowher` was granted passwordless sudo, managed
by the `users` role. The account is already in the `docker` group, which is
root-equivalent with no password (`docker run -v /:/host`), so the password on
sudo was not an actual security boundary — only an obstacle to automation. Runs
need no `--ask-become-pass`.

---

## 3. Constraints discovered

These shaped the design and are the non-obvious parts of the problem.

### 3.1 ufw does not filter Docker published ports

Docker inserts rules into the `nat` PREROUTING and `FORWARD` chains, evaluated
before ufw's INPUT rules. A container published with `-p 3000:3000` is LAN
reachable even under `ufw default deny incoming`.

Consequence: containerized services bind `127.0.0.1` only and are reached
through Caddy. Caddy is the sole container needing LAN exposure, via one
explicit `DOCKER-USER` rule. Native processes (llama-swap, beekeeper, sshd) are
governed by ufw normally.

Caddy is a security control in this design, not a convenience.

### 3.2 Beekeeper cannot run behind a subpath

No `ProxyFix`, `APPLICATION_ROOT`, or `SCRIPT_NAME` handling. Templates
hardcode `href="/admin"`, `href="/api/v1/docs"`, `href="/projects/..."`, and JS
issues `fetch("/api/stats")`.

Proxying at `lab.local/beekeeper` would break the UI, and would break it
*silently into Open WebUI*, whose routes would match the escaped paths.

Consequence: beekeeper is reached directly on `:5000`, LAN-only via ufw, with a
Caddy 302 redirect at `/beekeeper` for browser convenience. This also avoids
having to disable response buffering for its log-streaming endpoints.

Three existing consumers depend on that address and would break if it moved:
`BEEKEEPER_HOST=http://lab.local:5000` in the MCP config, `deploy.sh` polling
`/api/v1/busy`, and the base URL baked into generated agent SDKs.

### 3.3 Beekeeper will not install on Python 3.14

`setup.sh` searches for `python3.12`, `3.11`, `3.10`, then falls back to
`python3`. On this host only 3.14.4 exists, and none of the older versions are
available from apt.

`requirements.txt` pins `numpy<2.0`. The last 1.x release (1.26.4) supports
Python 3.9–3.12 only — no wheels for 3.13+, and no viable source build against
the newer C API. `bash setup.sh` fails at pip install.

Consequence: conda supplies the 3.12 interpreter (section 5.7). Conda is not a
workaround adopted for this constraint — it is existing, heavily used
infrastructure that beekeeper's runtime and Robert's own projects both depend
on. This constraint only fixes the version of one environment. `bcrypt==4.1.2`
and `tbparse==0.0.8` carry the same wheel-availability risk and should be
checked during implementation.

### 3.4 Upstream `setup.sh` owns the systemd unit

`setup.sh` templates the unit with `User=$CURRENT_USER` and calls `sudo` to
install it. Ansible runs `setup.sh` rather than writing the unit, so the
service user is whoever Ansible runs it as, and that user needs sudo rights.

Consequence: `beekeeper` gets `/bin/bash` and a home (it also builds venvs and
clones repos), plus a sudoers drop-in scoped to `systemctl` on the `beekeeper`
unit and writing that one unit file. Installed with `validate: visudo -cf %s` —
an unvalidated sudoers file is one of the few ways a playbook can lock the
operator out of the host.

### 3.5 Mismatched GPUs

vLLM tensor parallelism requires identical GPUs and will not split a model
across a 3090 and a 3060. The 3060 also sorts first by PCI bus ID, so "GPU 0"
is the *smaller* card by default.

Consequence: `CUDA_DEVICE_ORDER=PCI_BUS_ID` is set explicitly, and llama-swap
model definitions pin devices rather than assuming a default.

### 3.6 Unattended-upgrades versus a pinned driver

Left at defaults, unattended-upgrades will move the NVIDIA driver out from
under the container toolkit and break every GPU container without warning.

Consequence: scoped to `resolute` security origins, with `nvidia-*`,
`docker-ce*`, and `containerd*` on apt holds.

### 3.7 mDNS resolves exactly one name

`webui.lab.local` does not resolve without additional avahi configuration.
Routing is path-based on the single host `lab.local`.

---

## 4. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Storage | Extend root LV to 100% VG, `resizefs` | `/data` stays a directory on root; 81 GB free is not enough for model weights |
| Driver | Pin `595-server`, add `nvidia-utils-595-server` | Already installed and module-matched to the running kernel; only `nvidia-smi` is missing |
| Bind policy | Services bind default, ufw enforces | Survives IP changes; one place to audit. See 3.1 for the Docker caveat |
| Beekeeper deploy | Ansible preps host, runs upstream `setup.sh` idempotently | Upstream stays the source of truth for the unit |
| Beekeeper user | UID 2001, `/bin/bash`, home `/home/beekeeper` | nologin fights `setup.sh`, venv builds, and repo clones |
| `llm`, `files` users | Remain nologin | Only ever exec'd by systemd or docker; no execution path needs a shell |
| Python | Miniforge at `/opt/conda`, shared, with profile.d init; env `beekeeper` at 3.12 | Conda is load-bearing for beekeeper's runtime and for interactive project work, so it is installed for humans as well as services. conda-forge avoids the Anaconda ToS question and is smaller |
| Claude Code | Native installer, per-user for `robertcowher` | Self-updating, so Ansible ensures presence rather than pinning. The npm route would drag in a global node toolchain the host has no other use for |
| Repo layout | Playbook per host under `hosts/<name>/`, roles shared at top level | This host is a 1-of-1, and the second lab server will differ in kind — AMD/Intel GPUs, or a beekeeper worker — not merely in values. See section 7 |
| Hostnames | `lab.local`, HTTP only | Explicitly good enough for now; Caddy cannot issue certs for `.local` anyway |
| llama-swap | Pin `v253`, checksum-verified | Latest release as of this date |

---

## 5. Roles

Run order matters: users before storage so ownership applies; NVIDIA before
docker so the container toolkit finds a driver; docker before firewall so the
`DOCKER-USER` chain exists; conda before beekeeper.

`base → users → storage → nvidia → docker → firewall → conda → tools → llama_swap → webstack → beekeeper`

### 5.1 `base`
apt essentials (`build-essential`, `git`, `curl`, `ca-certificates`, `restic`,
`unattended-upgrades`), sshd config, timezone. Unattended-upgrades scoped per
3.6.

### 5.2 `users`
`ml` at GID 3000 first, then users at fixed UIDs:

| User | UID | Shell | Groups |
|---|---|---|---|
| `robertcowher` | 1000 | `/bin/bash` | `ml`, `docker`, `sudo` |
| `beekeeper` | 2001 | `/bin/bash` | `ml` |
| `llm` | 2002 | `/usr/sbin/nologin` | `ml`, `docker` |
| `files` | 2003 | `/usr/sbin/nologin` | — |

Numeric IDs are the mechanism by which `/data` ownership survives a rebuild.
`hosts/lab/verify.yml` asserts the numbers, not merely that the accounts exist.
They live in the fleet-wide `group_vars/all.yml`, not per host — see section 7.

`docker` group membership is root-equivalent; it is granted deliberately to
`robertcowher` and `llm` (llama-swap spawns backend containers).

### 5.3 `storage`
`community.general.lvol` with `size: 100%VG, resizefs: true` — idempotent, and
an online ext4 grow is routine. This is the only destructive-capable operation
in the playbook; it gets its own tag and runs early.

Then `/data/{models,datasets}` plus service state directories, group `ml`, with
`g+s` on directories so files written by llama-swap or beekeeper stay
group-readable. Without setgid the shared tree silently rots as soon as two
users write to it.

### 5.4 `nvidia`
Install `nvidia-utils-595-server` (supplies `nvidia-smi`). Add NVIDIA's
container-toolkit repo — distro-independent at `stable/deb/$arch`, verified
reachable — and install `nvidia-container-toolkit`, absent from Ubuntu's repos
by design. Apt-hold the branch.

Proof of success is not "package installed" but
`docker run --rm --gpus all <cuda-image> nvidia-smi`.

### 5.5 `docker`
docker-ce from the `resolute` suite (confirmed published), plus compose plugin.
`daemon.json` configures the nvidia runtime and log rotation — vLLM containers
are chatty, and their logs now share a filesystem with the OS.

### 5.6 `firewall`
ufw: allow `22`, `8080`, `5000` from `192.168.1.0/24`; default deny incoming.
One `DOCKER-USER` rule permitting `80` to the Caddy container. `9100`/`9400`
never leave loopback because they are never published.

### 5.7 `conda`
Conda is core infrastructure on this host, not a dependency workaround.
Beekeeper's runtime uses it and interactive project work under `robertcowher`
expects it, so it is installed for humans as well as for services.

Miniforge at `/opt/conda`, root-owned, group `ml`, read and execute for the
group — **not** group-writable. A writable shared prefix would let any `ml`
member mutate the `beekeeper` environment a running service depends on. Shared
environments are declared in `hosts/lab/vars.yml` and created by Ansible;
personal environments land in `~/.conda/envs` automatically, because conda
falls back to the first writable path in `envs_dirs`.

Shell initialization goes in `/etc/profile.d/conda.sh` rather than each user's
`.bashrc`, so `conda activate` works in a login shell for every `ml` member and
there is one place to change it. `auto_activate_base` is off — a `base` env
silently prepended to every shell's `PATH` is how the wrong `python` ends up
running a service.

Environment `beekeeper` at Python 3.12 supplies the `python3.12` binary that
`setup.sh` searches for.

### 5.8 `tools`
Two lists in `hosts/lab/vars.yml` so adding a tool is a one-line change, never
a role edit:

```yaml
tools_apt:  [htop, nvtop, iotop, ncdu, tree, ripgrep, fd-find, pciutils, sysstat,
             tmux, jq, unzip, nvme-cli, smartmontools]
tools_pipx: [nvitop]
```

Ubuntu 26.04 enforces PEP 668, so system-wide `pip install` fails outright and
nvitop is not packaged in the repos. pipx is used with `PIPX_HOME=/opt/pipx`
and `PIPX_BIN_DIR=/usr/local/bin` — the version-agnostic system-wide pattern,
preferred over `pipx --global`, which is newer than what 26.04 ships.

The `base`/`tools` split follows one rule: would removing this break the
server, or merely annoy the operator?

Operational note: nvitop must run as root to attribute GPU processes to users.
Unprivileged, it masks processes belonging to `beekeeper` and `llm`.

`tmux` is in `tools_apt` above.

Claude Code installs for `robertcowher` only — via the native installer to
`~/.local/bin`, run as that user, never as root. It self-updates, so Ansible's
job is to ensure it exists, not to pin a version: the task is guarded on the
binary's absence and does not re-run. Installing it system-wide or as root
would fight its own updater and put credentials under the wrong home.

### 5.9 `llama_swap`
`v253` tarball, checksum-verified, to `/usr/local/bin`. Config at
`/etc/llama-swap/config.yaml`. Systemd unit as `llm`, `Restart=always`, with
`CUDA_DEVICE_ORDER=PCI_BUS_ID` per 3.5. Models from `/data/models`. Backends
bind ephemeral loopback ports, reachable only by llama-swap.

### 5.10 `webstack`
One compose project at `/etc/docker/compose/webstack/`, driven by
`docker-compose@webstack.service` as the requirements specify. Open WebUI, File
Browser, node_exporter, and DCGM exporter all publish to `127.0.0.1` only.
Caddy is the only container publishing to the LAN.

File Browser runs as UID 2003 so files on disk carry correct ownership, and is
configured with a base URL for subpath hosting.

Routing:

| Path | Target |
|---|---|
| `lab.local/` | Open WebUI (`127.0.0.1:3000`) |
| `lab.local/files` | File Browser (`127.0.0.1:8081`) |
| `lab.local/beekeeper` | 302 redirect to `http://lab.local:5000/` |

### 5.11 `beekeeper`
Clone `git@github.com:bobcowher/beekeeper.git` to `/home/beekeeper/beekeeper`.
Run `setup.sh -y` with `/opt/conda/envs/beekeeper/bin` on `PATH`, guarded so it
executes only when the checkout SHA changed or the venv is absent. Sudoers
drop-in per 3.4.

---

## 6. Final bind table

| Service | Bind | Reached via | Enforced by |
|---|---|---|---|
| SSH | LAN | `:22` | ufw |
| Caddy | LAN | `:80` | ufw + `DOCKER-USER` |
| Open WebUI | `127.0.0.1:3000` | `lab.local/` | not published |
| File Browser | `127.0.0.1:8081` | `lab.local/files` | not published |
| llama-swap | LAN | `:8080` | ufw |
| beekeeper | LAN | `:5000` | ufw |
| node_exporter | `127.0.0.1:9100` | local scrape | not published |
| DCGM exporter | `127.0.0.1:9400` | local scrape | not published |
| vLLM / llama.cpp | `127.0.0.1`, ephemeral | llama-swap only | not published |

Nothing is exposed to the internet.

---

## 7. Repo layout

```
inventory/hosts.yml       # every host; lab ansible_host=192.168.1.30
group_vars/all.yml        # fleet invariants only: UIDs, GIDs, LAN subnet
hosts/lab/main.yml        # this host's playbook — its roles, in order, tagged
hosts/lab/vars.yml        # host specifics: driver branch, pinned versions, tool lists
hosts/lab/verify.yml      # host-specific end-state assertions
roles/{base,users,storage,nvidia,docker,firewall,conda,tools,llama_swap,webstack,beekeeper}/
requirements.md           # source reference sheet (superseded where it conflicts)
docs/superpowers/specs/   # this document
```

Run with:

```
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --ask-become-pass
```

### 7.1 Why this is not the conventional layout

The usual `site.yml` plus inventory-groups structure assumes variation between
hosts is *parametric*: the same roles everywhere, different values. That holds
when you stamp out hundreds of one server class. It does not hold here.

This host is a 1-of-1, and the second lab server is expected to differ in kind
rather than in values — AMD or Intel GPUs, or a beekeeper worker running a
subset of the services. Forced into the conventional layout, that variation has
nowhere to live except inside the roles, and `when: gpu_vendor == 'nvidia'`
branches accumulate until no host's configuration can be understood without
mentally evaluating conditionals.

A playbook per host puts the variation in the composition layer, where it reads
as a list. Concretely: when a second host has AMD GPUs it gets a **new**
`amd_gpu` role that its playbook includes *instead of* `nvidia` — not a vendor
branch inside `nvidia`. Roles stay single-purpose; each playbook states which
purposes that host wants, and in what order.

### 7.2 Which variables live where

`group_vars/all.yml` holds fleet invariants; `hosts/<name>/vars.yml` holds
everything else. The test: **if two lab servers would have to agree on it, it
is fleet-wide.**

Numeric UIDs and GIDs are the load-bearing case. The entire reason they are
pinned (section 5.2) is so `/data` ownership survives a rebuild. Copy-pasted
into two host files, one eventually drifts, and restoring `/data` onto the
wrong box silently produces wrong ownership — the exact failure the pinning
exists to prevent. That value must exist in one place.

Driver branches, pinned release versions, tool lists, and conda environments
are host-specific and belong under `hosts/lab/`.

### 7.3 No `site.yml` yet

For a single host it is ceremony. It earns its place when there is a second
host and a real reason to run both in one command; at that point it becomes a
thin file importing each host's playbook.

---

## 8. Verification

`hosts/lab/verify.yml` asserts end state independently of Ansible's own change
reporting. `changed=0` proves the tasks ran, not that the host is correct.

- Numeric UIDs and GIDs match section 5.2 exactly
- `g+s` set on `/data` directories
- Root LV filled the volume group
- Each systemd unit active
- `ss -ltn` shows every port on the address in section 6 — in particular, that
  nothing containerized is listening on a LAN address
- `nvidia-smi` succeeds on the host **and** inside `--gpus all`
- `nvitop -1` returns cleanly (exercises driver, NVML, and Python bindings)
- `conda --version` resolves in a login shell for an `ml` member, and
  `/opt/conda/envs/beekeeper/bin/python --version` reports 3.12
- `claude --version` succeeds as `robertcowher`
- HTTP probe through Caddy reaches Open WebUI and File Browser
- `curl http://192.168.1.30:5000/api/v1/busy` returns valid JSON

---

## 9. Corrections to `requirements.md`

| Doc says | Reality |
|---|---|
| Ubuntu 24.04 LTS | 26.04.1 LTS, `resolute` |
| Beekeeper port TBD | 5000 |
| `beekeeper` shell `/usr/sbin/nologin` | `/bin/bash` with a home; nologin is incompatible with upstream `setup.sh` |
| Ports 3000 and 8081 bind LAN *and* are reached "via Caddy" | Mutually exclusive. They bind loopback and are reached only via Caddy |
| "No service binds 0.0.0.0" | Aspirational. Several services bind 0.0.0.0 by default; ufw and non-publication enforce the intent instead |
| `restic-local.timer`, `restic-remote.timer` | Deferred; no backup targets exist yet |

---

## 10. Deferred

- **Tailscale** — excluded from this iteration by request.
- **Backups** — `restic` is installed; no repos, timers, retention, or
  credentials. **This is the largest outstanding risk.** `/data` lives on root
  with no redundancy, so a disk failure or reinstall loses models, datasets,
  and beekeeper's training history. Fixed UIDs make a restore correct, but only
  once something is being backed up.
- **`disk-check.timer`** — script undefined.
- **Beekeeper state location** — `data/beekeeper.db`, `projects/`,
  `.secret_key`, and `config.properties` live inside the checkout, which
  `deploy.sh` subjects to `git reset --hard` and `rm -rf venv`. It survives
  because those paths are gitignored; a stray `git clean -xdf` would destroy
  the training history. Moving state to `/data/beekeeper` is a change to
  beekeeper's own path resolution and belongs in that repo.
- **Beekeeper dependency pins** — `numpy<2.0` blocks any Python above 3.12.
  Conda works around it here; removing the pin upstream is the real fix.
- **Beekeeper subpath support** — prerequisite for real hostnames and TLS
  behind Caddy. Belongs in the beekeeper repo (see 3.2).

---

## 11. Next step

Implementation plan via the writing-plans skill.
