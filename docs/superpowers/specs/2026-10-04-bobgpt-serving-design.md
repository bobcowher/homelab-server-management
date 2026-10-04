# Serving bobgpt on lab, behind the existing Open WebUI

Status: approved design, not yet implemented
Date: 2026-10-04

## Goal

Chat with trained `llm_bobgpt` checkpoints from the Open WebUI already running
on lab, and keep iterating on the model without touching this (the Ansible)
repository. Every change that is about *bobgpt* -- generation code, chat
template, dependencies, how the server starts, which runs are exposed -- must
be deployable from the `llm_bobgpt` repository alone.

Non-goals: inference speed, quantisation, multi-user concurrency, exposing
bobgpt outside the LAN.

## Ownership

**This repository does deployment only.** `github.com/bobcowher/bobgptv1` is
owned by Robert and another agent; nothing here creates, edits or commits a
file in it. Clarified by Robert on 2026-10-04: *"Your work is 100%
deployment. Think of yourself as a DevOps engineer."*

The sections below describing the server are therefore a **contract**, not a
work plan for this side: they record what the host provides and what the
repository must provide in return. The host-side work is planned in
`docs/superpowers/plans/2026-10-04-bobgpt-host-plumbing.md`.

## What already exists

- `llm_bobgpt/api.py` is an OpenAI-compatible FastAPI app: `GET /v1/models`
  and `POST /v1/chat/completions`, streaming and blocking.
- `llm_bobgpt/docs/SERVING.md` specifies the wire contract in detail and
  describes a three-layer streaming design the code has not fully adopted.
- Checkpoints are **already on lab**, written there by beekeeper training runs:
  `/data/datasets/bobgptv1/checkpoints/<run>/model.pth`, one 702 MB file per
  run directory (`run25`, `run28`, `run29`, `run30`, `pretrain`, `posttrain`).
  `checkpoints/` is gitignored, so the repository carries code and never
  weights. There is no artifact-transport problem to solve.
- Open WebUI runs in the `webstack` compose project and currently has exactly
  one upstream, `OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1`,
  which is llama-swap.
- `robertcowher` already holds `ALL=(ALL) NOPASSWD: ALL` on lab and is already
  in group `ml`, which owns the checkpoint tree.

## Decisions

### Resident GPU service, started by hand

Agreed with Robert on 2026-10-04: the service loads on the GPU and stays
loaded, and it is **not enabled at boot**. He starts it when he wants it.
Because lab powers itself off overnight, it is off again every morning.

The alternatives considered and rejected were CPU-only inference (no CUDA
context, but slower) and GPU with systemd socket activation plus an idle exit
(no context when unused, but it needs `uvicorn --fd` and more moving parts).

The consequence is handled explicitly in "Changes to the power role" below: a
process holding a CUDA context would otherwise veto the overnight poweroff
forever, because a CUDA context lives for the life of the process once
initialised -- unloading the model frees VRAM but the process stays listed in
`nvidia-smi --query-compute-apps`.

### Several checkpoints at once, auto-discovered

`/v1/models` lists every run found under the checkpoint root, as
`bobgpt-<dirname>`, so two runs can be compared in the same Open WebUI
session. Dropping `run31/model.pth` into the tree makes it appear on the next
`/v1/models` call: no restart, no redeploy, no edit to either repository.

### Architecture inferred from the checkpoint, not declared

`api.py` currently hardcodes `GPT_CONFIG_124M` next to
`checkpoints/model.pth`. Since the repo also declares `GPT_CONFIG_406M` and
`GPT_CONFIG_838M`, the checkpoint and its architecture are a single unit and
must not be specified in two places.

Verified on 2026-10-04 against `run30_posttrain_model.pth` and
`run25_model.pth`: the whole config is recoverable from tensor shapes.

| Field | Source |
|---|---|
| `vocab_size` | `tok_emb.weight.shape[0]` |
| `context_length` | `pos_emb.weight.shape[0]` |
| `emb_dim` | `tok_emb.weight.shape[1]` |
| `n_layers` | highest `trf_blocks.<n>.` index, plus one |
| `n_heads` | `emb_dim // 64` |
| `qkv_bias` | whether any `W_query.bias` key is present |
| `drop_rate` | irrelevant under `.eval()`; set 0.0 |

`n_heads` is the one inference that is not a direct read. It relies on
`head_dim == 64`, which holds for all three declared configs (768/12,
1024/16, 1280/20). The server therefore **refuses to load** a checkpoint whose
`emb_dim` is not divisible by 64 rather than guessing, and an optional
`config.json` beside `model.pth` overrides inference entirely.

### Standalone service, second Open WebUI upstream

Rejected: registering bobgpt as a llama-swap model. llama-swap maps one model
id to one spawned process, so each new run would need an entry in
`llama_models` in *this* repository -- precisely the coupling this design
exists to avoid. It also offers VRAM eviction that a 0.7 GB model does not
need.

Rejected for now: a container image. Cleaner dependency isolation, but it
turns the iteration loop into an image rebuild and adds the nvidia container
runtime for no gain. Revisit if the dependency set becomes awkward.

## The boundary

Ansible contributes only facts about this host. Nothing on this side names a
run, a checkpoint file, a model size, a config constant, or a version.

| Owned by this repo | Why it cannot live in `llm_bobgpt` |
|---|---|
| `bobgpt` system user, member of group `ml` | needs root; `ml` grants read on the checkpoint tree |
| The clone: destination path and branch | something must place the code |
| `/opt/bobgpt`, owned `robertcowher:ml` — the checkout and venv live here | needs root to create under `/opt` |
| `BOBGPT_PYTHON`, the interpreter the venv must be built from | torch has no wheels for the 3.14 that ships natively |
| The systemd unit, whose `ExecStart` is a script **in** `llm_bobgpt` | needs root to install |
| `BOBGPT_CHECKPOINT_ROOT`, `BOBGPT_DEVICE`, `BOBGPT_PORT`, `BOBGPT_MAX_LOADED` as `Environment=` | host paths and hardware |
| The bind address and port: `127.0.0.1:8100` | must not collide with 3000/5000/8080, and must not reach the LAN |
| The added Open WebUI upstream (see below) | the compose file is in this repo |
| The power-role changes below | that role is in this repo |

Everything else is owned by `llm_bobgpt`: `api.py` and its layers, the chat
template, discovery, the LRU, `serve.sh` (so the repo decides uvicorn flags,
worker count and log format), `requirements-serve.txt`, and `deploy.sh`.

`BOBGPT_DEVICE` is a variable rather than a constant because llama-swap's
resident-lane model `gemma-4-12b` is pinned to `device=0`, the 3060, and a Q4
12B at 32k context occupies most of that card. bobgpt's 0.7 GB should still
fit, but the choice has to be flippable per session.

## The Open WebUI upstream

Open WebUI today has the singular `OPENAI_API_BASE_URL` pointing at
llama-swap. Serving two upstreams means moving to the plural forms, which take
a `;`-separated list and must be the same length:

```
OPENAI_API_BASE_URLS=http://host.docker.internal:8080/v1;http://host.docker.internal:8100/v1
OPENAI_API_KEYS=none;none
```

`host.docker.internal` resolves via the existing `extra_hosts: host-gateway`
entry, which is why this survives lab changing IP -- the same reasoning the
compose file already records for llama-swap. The exact variable names are to
be confirmed against the running `ghcr.io/open-webui/open-webui:main` image
during implementation; if they have changed, the fallback is a Caddy route
that merges both upstreams under one base URL.

This is the one piece of the design that is a genuine one-time change in this
repository. After it, nothing here needs to change for bobgpt again.

## Service design (owned by `bobgptv1`, recorded here as the contract)

`serve.sh` starts uvicorn against `api.py`, which gains:

1. **Discovery.** Glob `$BOBGPT_CHECKPOINT_ROOT/*/model.pth`; expose each as
   `bobgpt-<dirname>`; `created` is the file's mtime.
2. **Architecture inference**, per the table above, with the sidecar override
   and the hard refusal.
3. **Lazy loading** on first request per id, with an LRU capped by
   `BOBGPT_MAX_LOADED` (default 2) so a tree of thirty runs does not try to
   hold thirty models.
4. **The three-layer streaming design from `SERVING.md`**: token generator,
   then a text stream owning decode plus stop-string holdback plus
   `finish_reason`, then SSE framing. The non-streaming path is rebuilt on the
   same text stream so the two cannot drift.

Bugs in the current `api.py` that this fixes, all already described in
`SERVING.md`:

- Streaming calls `.find("### End")` on each token's decoded text in
  isolation. `### End` spans several tokens, so the match never fires and
  streaming generation always runs to `max_tokens`.
- `id` is the literal `"5"` on every response. It must be unique per request
  (`"chatcmpl-" + uuid4().hex`) or Open WebUI will eventually merge messages.
- `V1Models(..., queue_depth=3)` passes a field the model does not declare.
  Pydantic drops it silently; it should go.
- Split multi-byte UTF-8 characters are decoded per token and can emit `U+FFFD`.

## Deploy and update loop

The checkout is owned by `robertcowher:ml`, so `git pull` needs no sudo. Only
the restart does, and that grant already exists.

```bash
# llm_bobgpt/deploy.sh, run on lab
git pull
pip install -r requirements-serve.txt      # into the bobgpt conda env
sudo systemctl restart bobgpt
```

Ansible does not manage Python dependencies at all. It creates
`/opt/bobgpt` owned by `robertcowher:ml` and publishes `BOBGPT_PYTHON`
(`/opt/conda/envs/py312/bin/python3.12`, because torch has no wheels for the
3.14 that ships natively). Building the venv and installing into it is
`deploy.sh`'s job. Adding a dependency therefore never touches this
repository, and no package name or version appears in it.

Because the checkout is owned by `robertcowher` rather than by the service
user, `git pull` and `pip install` need no sudo. Only the restart does, and
that grant already exists.

`requirements.txt` currently pulls in `tensorflow`, needed only by
`gpt_download.py`. A separate `requirements-serve.txt` keeps several hundred
megabytes out of the service environment.

If the blanket NOPASSWD grant is ever tightened, this is the scoped
replacement, and it is the only sudoers line this design needs:

```
robertcowher ALL=(root) NOPASSWD: /usr/bin/systemctl start bobgpt, \
    /usr/bin/systemctl stop bobgpt, /usr/bin/systemctl restart bobgpt, \
    /usr/bin/systemctl status bobgpt
```

## Changes to the power role

A resident CUDA process would veto the overnight poweroff on every run. Two
changes, which leave the check stronger than it is today rather than weaker:

1. **The GPU signal excludes bobgpt by cgroup**, not by disabling the check.
   It counts CUDA processes that are *not* in `bobgpt.service`'s cgroup, so it
   still catches the hand-run tmux script or notebook the signal exists for.
   The excluded unit is a variable defaulting to empty, so the behaviour is
   unchanged on a host without bobgpt.
2. **A new bobgpt-activity signal**, mirroring the existing llama-swap one: a
   completion request in the last `power_idle_window_minutes` vetoes the
   shutdown.

Net effect: a forgotten but idle service does not stop the box powering off; a
conversation in progress does. Change 2 also closes an existing gap -- today a
bobgpt conversation at 23:59 would not prevent the midnight poweroff, because
the idle check only reads llama-swap's journal.

Both changes need cases in `scripts/test_idle_checks.sh`, which `verify.yml`
already runs on every deploy.

## Verification

In `llm_bobgpt`, unit tests for the text-stream layer, runnable with no model
and no GPU, covering the cases `SERVING.md` lists: `### End` split across
tokens, a near miss (`### Ending`), an emoji split across tokens, trailing
`\n\n` before the end marker, and running out at `max_tokens` with text still
held.

In this repo, `verify.yml` assertions:

- the unit exists and is **not** enabled at boot (assert the inverse too: that
  a disabled unit is actually stopped -- the pattern the WoL and timer bugs
  both needed)
- the `bobgpt` user can read `BOBGPT_CHECKPOINT_ROOT`
- Open WebUI's upstream list contains the bobgpt base URL
- with the service started, `/v1/models` returns at least one discovered run

The last one is the only assertion that proves the feature rather than the
configuration, and it is the reason the others are not sufficient.

## Implementation split

The work divides into two independent streams that meet only at the HTTP
contract, so they can be built and tested in either order:

- **`bobgptv1`** (Robert and another agent): discovery, architecture
  inference, the LRU, wiring the streaming layers into `api.py`, `serve.sh`,
  `requirements-serve.txt`, and `deploy.sh`. As of 2026-10-04 layers 1 and 2
  are already built there and uncommitted on branch `fastapi`: `generate()`
  now delegates to `generate_streaming()`, and `text_stream.py` implements the
  stop-holdback, trailing-whitespace and split-UTF-8 handling with six tests
  in `tests/test_text_stream.py`. What remains is layer 3 — wiring it into
  `api.py`, which still matches stop strings per token.
- **This repo** (deployment): the `bobgpt` user, `/opt/bobgpt`, the host facts
  file, the bootstrap clone, the unit, the Open WebUI upstream, the two
  power-role changes, the `verify.yml` assertions, and the RUNBOOK.

The only coupling is the contract above, so the two can proceed in either
order. The host side is useful before the repo side exists: it provisions
everything and warns, legibly, that `serve.sh` is still missing.

## Open questions

- Multi-turn conversations: the training data is all single-turn (system,
  question, answer), so multi-turn works mechanically but is out of
  distribution. `SERVING.md` already records this.
- Context trimming policy at 1024 tokens: oldest turns first, and whether the
  system turn is always kept.
- Whether `/v1/models` should hide runs whose shapes cannot be inferred, or
  list them and fail on use. Listing and failing loudly is probably better.

## Out of scope

Exposing bobgpt beyond the LAN; authentication on the bobgpt port (it binds
127.0.0.1 and is reached only via the compose network); the GGUF/llama.cpp
export path, which stays parked in `SERVING.md`.
