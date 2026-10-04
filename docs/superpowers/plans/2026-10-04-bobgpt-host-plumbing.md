# bobgpt Host Plumbing Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give lab everything needed to run a bobgpt server that the
`bobgptv1` repository supplies, without this repository ever knowing a run
name, checkpoint path, model size, Python package or version.

**Architecture:** Ansible provisions a service user, a directory it owns, a
host-facts environment file, a bootstrap clone, and a systemd unit whose
`ExecStart` is a script inside the cloned repository. The repository owns all
behaviour. Open WebUI gains a second upstream. The power role learns to
tolerate a resident CUDA process without losing the signal it exists for.

**Tech Stack:** Ansible, systemd, bash, Docker Compose (Open WebUI), conda
(interpreter only).

**Spec:** `docs/superpowers/specs/2026-10-04-bobgpt-serving-design.md`

## Scope

**This plan is deployment only.** The `bobgptv1` repository is owned by Robert
and another agent. No task here creates, edits or commits a file in it. Where
this plan needs something from that repository it defines a *contract* and
asserts the contract is met, failing with a message that names what is
missing.

## Global Constraints

- Nothing in this repository may name a run, a checkpoint file, a model size,
  a config constant, a Python package, or a version of the bobgpt code.
- The service must **not** be enabled at boot. Assert the inverse too: that a
  disabled unit is actually stopped.
- The service binds `127.0.0.1:8100` only. Nothing is published to the LAN.
- `robertcowher` already holds `ALL=(ALL) NOPASSWD: ALL` and is in group `ml`.
  Add no sudoers file.
- Ansible performs the **initial clone only** (`update: false`). `deploy.sh`
  owns updating the checkout; a playbook run must never revert a pull or a
  branch switch.
- Every change to `lab-idle-shutdown.sh.j2` needs a case in
  `scripts/test_idle_checks.sh`, which `verify.yml` runs on every apply.
- Defaults must make the power-role changes a **no-op** on a host with no
  bobgpt, so the role stays correct if bobgpt is never installed.

## The contract with `bobgptv1`

Ansible provides, and the repository may rely on:

| Provided | Value |
|---|---|
| `/etc/bobgpt/host.env` | every host fact below, as `KEY=value`, world-readable |
| `BOBGPT_SRC` | `/opt/bobgpt/src` — the checkout, owned `robertcowher:ml`, mode 2775 |
| `BOBGPT_VENV` | `/opt/bobgpt/venv` — not created by Ansible; `deploy.sh` owns it |
| `BOBGPT_PYTHON` | `/opt/conda/envs/py312/bin/python3.12` — torch has no 3.14 wheels |
| `BOBGPT_CHECKPOINT_ROOT` | `/data/datasets/bobgptv1/checkpoints` |
| `BOBGPT_DEVICE` | `cuda:0` |
| `BOBGPT_PORT` | `8100` |
| `BOBGPT_HOST` | `127.0.0.1` |
| `BOBGPT_MAX_LOADED` | `2` |

The repository must provide `$BOBGPT_SRC/serve.sh`, executable, which starts
an OpenAI-compatible server listening on `$BOBGPT_HOST:$BOBGPT_PORT`. The unit
runs it with `/etc/bobgpt/host.env` already loaded. Anything else — the venv,
dependencies, uvicorn flags, logging — is the repository's business.

## Review Focus

Failure modes the spec implies that no obvious task would otherwise cover:

1. **`serve.sh` does not exist yet.** The unit will fail `203/EXEC` with a
   cryptic message. Task 5 asserts the entrypoint exists and names it in the
   failure, so the cause is legible. The assertion must *warn*, not fail the
   play, while the repo side is outstanding.
2. **The GPU exclusion silently excludes everything.** An empty or wrong unit
   name must exclude *nothing* rather than every PID. Covered in Task 1.
3. **The exclusion hides a real training run.** A PID not in bobgpt's cgroup
   must still veto. Covered in Task 1.
4. **Open WebUI's plural env vars differ from the assumption.** The dropdown
   would silently lose a model. Task 4 verifies against the running container
   rather than trusting the variable name.
5. **A playbook run reverts a deploy.** `update: false` plus a verify
   assertion that the checkout is a git repo but not pinned to a commit.

---

### Task 1: GPU signal excludes one named unit's cgroup

**Files:**
- Modify: `roles/power/templates/lab-idle-shutdown.sh.j2`
- Modify: `hosts/lab/vars.yml`
- Test: `scripts/test_idle_checks.sh`

**Interfaces:**
- Produces: shell function `not_excluded()` in the installed script, extracted
  and unit-tested by the harness exactly as `sar_data` and
  `sessions_from_states` already are.

- [ ] **Step 1: Add the failing test cases**

In `scripts/test_idle_checks.sh`, after the `== session state filter ==`
block, add a block that extracts `not_excluded` from the installed script and
feeds it fixtures:

```bash
echo
echo "== gpu exclusion filter =="

excl_prog=$(sed -n '/^not_excluded()/,/^}/p' "$REAL" | sed -n "s/.*awk -v ex=\"\\$1\" '\\(.*\\)'.*/\\1/p")
if [[ -z "$excl_prog" ]]; then
    echo "FAIL  could not extract not_excluded filter from $REAL"
    fail=$(( fail + 1 ))
else
    excl_case() {
        local label="$1" ex="$2" want="$3"; shift 3
        local got
        got=$(printf '%s\n' "$@" | awk -v ex="$ex" "$excl_prog" | grep -c .)
        if [[ "$got" == "$want" ]]; then
            echo "PASS  $label"; pass=$(( pass + 1 ))
        else
            echo "FAIL  $label -- expected $want, got $got"; fail=$(( fail + 1 ))
        fi
    }
    # An empty exclusion list must exclude NOTHING. Getting this backwards
    # turns the GPU veto off entirely and is invisible: the box simply stops
    # refusing to shut down.
    excl_case "empty exclusion keeps every pid" "" 2 "1234" "5678"
    excl_case "an excluded pid is dropped" "5678" 1 "1234" "5678"
    excl_case "a foreign pid still counts" "5678" 1 "1234"
    excl_case "all pids excluded counts zero" "1234 5678" 0 "1234" "5678"
    # A pid that merely CONTAINS an excluded pid is a different process.
    excl_case "substring is not a match" "567" 2 "5678" "1234"
fi
```

- [ ] **Step 2: Run it and watch it fail**

```bash
scp scripts/test_idle_checks.sh lab.local:/tmp/ && ssh lab.local 'sudo bash /tmp/test_idle_checks.sh' | sed -n '/gpu exclusion/,$p'
```
Expected: `FAIL  could not extract not_excluded filter`.

- [ ] **Step 3: Implement**

In `lab-idle-shutdown.sh.j2`, add the knob next to the others:

```bash
GPU_EXCLUDE_UNIT="{{ power_gpu_exclude_unit | default('') }}"
```

Replace the GPU section with:

```bash
# --- GPU ---------------------------------------------------------------------
#
# Catches CUDA work started outside beekeeper entirely -- a script run by hand
# in tmux, a notebook -- which no API on this box would ever report.
#
# One unit may be excluded by cgroup. bobgpt is a resident GPU service started
# by hand, and a CUDA context lives for the life of the process once
# initialised: unloading the model frees VRAM but the process stays listed
# here forever. Counting it would veto every overnight shutdown.
#
# Excluded by IDENTITY, not by turning the check off. Any OTHER process holding
# a context still vetoes, which is the whole point of this signal. An empty or
# unknown unit name excludes nothing, so this is a no-op on a host without it.
not_excluded() { awk -v ex="$1" 'BEGIN{n=split(ex,a," ");for(i=1;i<=n;i++)e[a[i]]=1} $1 ~ /^[0-9]+$/ && !($1 in e)'; }

excluded_pids=""
if [[ -n "$GPU_EXCLUDE_UNIT" ]]; then
    # The cgroup, not MainPID: uvicorn may fork workers, and every one of them
    # holds its own context.
    cg="/sys/fs/cgroup/system.slice/${GPU_EXCLUDE_UNIT}/cgroup.procs"
    [[ -r "$cg" ]] && excluded_pids=$(tr '\n' ' ' < "$cg")
fi

gpu_procs=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null \
    | tr -d ' ' | not_excluded "$excluded_pids" | grep -c .)
report "gpu compute processes" "${gpu_procs}$([[ -n "$excluded_pids" ]] && echo " (excluding ${GPU_EXCLUDE_UNIT})")"
[[ "$gpu_procs" -gt 0 ]] && veto "${gpu_procs} process(es) holding a CUDA context"
```

Add to `hosts/lab/vars.yml` in the power block:

```yaml
# One systemd unit whose CUDA processes do not count as activity, excluded by
# cgroup. Empty means exclude nothing. See the GPU section of the idle script.
power_gpu_exclude_unit: "bobgpt.service"
```

- [ ] **Step 4: Run the tests**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags power
```
Expected: the harness reports all cases passing, and the live dry-run still
prints a `gpu compute processes` line.

- [ ] **Step 5: Commit**

```bash
git add roles/power hosts/lab/vars.yml scripts/test_idle_checks.sh
git commit -m "feat(power): exclude one unit's cgroup from the GPU idle signal"
```

---

### Task 2: A bobgpt request in the window vetoes the shutdown

**Files:**
- Modify: `roles/power/templates/lab-idle-shutdown.sh.j2`
- Modify: `hosts/lab/vars.yml`
- Test: `scripts/test_idle_checks.sh`

**Interfaces:**
- Consumes: `IDLE_MINUTES`, `report()`, `veto()` from Task 1's file.
- Produces: `BOBGPT_UNIT` knob; a `bobgpt inference` report line.

This closes a gap that exists today: the idle check reads llama-swap's journal
only, so a bobgpt conversation at 23:59 would not stop the midnight poweroff.

- [ ] **Step 1: Add the failing test case**

```bash
echo
echo "== bobgpt activity =="

# An empty unit name must not veto, or a host without bobgpt could never
# shut down.
check "no bobgpt unit does not veto" "bobgpt inference         not installed" \
    's/^BOBGPT_UNIT=.*/BOBGPT_UNIT=""/'

# Pointed at a unit that exists and has journal lines matching a completion
# request, it must veto. systemd-journald itself is a safe stand-in: it always
# exists, and the grep is what decides.
check "bobgpt requests veto" "bobgpt inference request(s)" \
    's/^BOBGPT_UNIT=.*/BOBGPT_UNIT="systemd-journald.service"/' \
    's#grep -cE .\"(POST\|GET) /v1/(chat/completions\|completions)#grep -cE "."#'
```

- [ ] **Step 2: Run it and watch it fail**

Expected: both cases FAIL, because `BOBGPT_UNIT` does not exist in the script
so the sed is a no-op and no `bobgpt inference` line is printed.

- [ ] **Step 3: Implement**

Add the knob:

```bash
BOBGPT_UNIT="{{ power_bobgpt_unit | default('') }}"
```

Add after the llama-swap section:

```bash
# --- bobgpt inference --------------------------------------------------------
#
# Same reasoning as llama-swap above, for the from-scratch server: the GPU
# check cannot see it (its cgroup is excluded, by design) and its load is
# negligible, so without this a conversation in progress would not stop the
# box powering off underneath it.
#
# /v1/models is excluded deliberately -- Open WebUI polls it to build the model
# dropdown, and verify.yml calls it on every apply. Counting those would keep
# the box awake on its own monitoring.
if [[ -z "$BOBGPT_UNIT" ]]; then
    report "bobgpt inference" "not installed"
else
    bobgpt_hits=$(journalctl -u "$BOBGPT_UNIT" --since "-${IDLE_MINUTES}min" \
        --no-pager -q 2>/dev/null \
        | grep -cE '"(POST|GET) /v1/(chat/completions|completions)' )
    report "bobgpt inference" "${bobgpt_hits} request(s) in ${IDLE_MINUTES}m"
    [[ "$bobgpt_hits" -gt 0 ]] && veto "${bobgpt_hits} bobgpt request(s) in the last ${IDLE_MINUTES} minutes"
fi
```

Add to `hosts/lab/vars.yml`:

```yaml
# The bobgpt service unit, read for recent inference requests. Empty disables
# the signal. Paired with power_gpu_exclude_unit: that one stops bobgpt's idle
# CUDA context from blocking every shutdown, this one makes bobgpt's actual USE
# block one.
power_bobgpt_unit: "bobgpt.service"
```

- [ ] **Step 4: Run the tests** — as Task 1 Step 4.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(power): veto the shutdown on recent bobgpt inference"
```

---

### Task 3: The bobgpt role

**Files:**
- Create: `roles/bobgpt/tasks/main.yml`
- Create: `roles/bobgpt/templates/bobgpt.service.j2`
- Create: `roles/bobgpt/templates/host.env.j2`
- Modify: `hosts/lab/vars.yml`
- Modify: `hosts/lab/main.yml`

**Interfaces:**
- Produces: `bobgpt.service` (installed, not enabled); `/etc/bobgpt/host.env`;
  `/opt/bobgpt/src` checkout owned `robertcowher:ml`.

- [ ] **Step 1: Variables**

```yaml
# --- bobgpt ------------------------------------------------------------------
# A from-scratch GPT server from github.com/bobcowher/bobgptv1, served behind
# the existing Open WebUI. This repository provisions the host and nothing
# else: the unit's ExecStart is a script INSIDE that checkout, so how the
# server starts is owned there. See
# docs/superpowers/specs/2026-10-04-bobgpt-serving-design.md.
bobgpt_user: bobgpt
bobgpt_root: /opt/bobgpt
bobgpt_repo: https://github.com/bobcowher/bobgptv1.git
# Bootstrap only. Ansible clones once and never updates (update: false), so a
# `git pull` or a branch switch from deploy.sh is never reverted.
bobgpt_branch: fastapi
bobgpt_host: 127.0.0.1
bobgpt_port: 8100
bobgpt_checkpoint_root: /data/datasets/bobgptv1/checkpoints
# Which card. gemma-4-12b is llama-swap's resident-lane model and is pinned to
# device 0, so if both are loaded this may need to move. Flippable on purpose.
bobgpt_device: "cuda:0"
bobgpt_max_loaded: 2
# torch has no wheels for the 3.14 that ships natively, so the venv deploy.sh
# builds must come from the conda 3.12.
bobgpt_python: "{{ conda_prefix }}/envs/py312/bin/python3.12"
```

Add the role to `hosts/lab/main.yml` **before** `power`, because the idle
check reads bobgpt's cgroup and journal and is dry-run at the end of its own
role:

```yaml
    - { role: beekeeper, tags: [beekeeper] }
    - { role: bobgpt, tags: [bobgpt] }
```

- [ ] **Step 2: `roles/bobgpt/templates/host.env.j2`**

```
# Managed by Ansible. See roles/bobgpt/tasks/main.yml.
#
# Every host-specific fact the bobgpt server needs, in one file, so that the
# systemd unit and the repository's own deploy.sh read the same values from the
# same place. Nothing here names a run, a checkpoint, a model size or a
# package: those belong to the repository.
BOBGPT_SRC={{ bobgpt_root }}/src
BOBGPT_VENV={{ bobgpt_root }}/venv
BOBGPT_PYTHON={{ bobgpt_python }}
BOBGPT_CHECKPOINT_ROOT={{ bobgpt_checkpoint_root }}
BOBGPT_HOST={{ bobgpt_host }}
BOBGPT_PORT={{ bobgpt_port }}
BOBGPT_DEVICE={{ bobgpt_device }}
BOBGPT_MAX_LOADED={{ bobgpt_max_loaded }}
```

- [ ] **Step 3: `roles/bobgpt/templates/bobgpt.service.j2`**

```
[Unit]
Description=bobgpt from-scratch GPT server
# Open WebUI reaches this over the docker bridge, and the checkpoints live on
# /data, so both must be up first.
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User={{ bobgpt_user }}
Group=ml
WorkingDirectory={{ bobgpt_root }}/src
EnvironmentFile=/etc/bobgpt/host.env
# The entrypoint is a script in the CHECKOUT, not a command composed here.
# That is the whole boundary: uvicorn flags, worker count and log format are
# the repository's to change without touching Ansible.
ExecStart={{ bobgpt_root }}/src/serve.sh
Restart=no
# Writable paths are explicit. The service reads its code and weights and
# writes nothing: the checkout belongs to robertcowher, the checkpoints are
# read-only, and a service that cannot write them cannot corrupt a run.
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadOnlyPaths={{ bobgpt_checkpoint_root }}
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

Note: `[Install]` is present but the unit is installed with `enabled: false`,
so the symlink is never created. Keeping the section means
`systemctl enable bobgpt` works if Robert ever wants it at boot.

- [ ] **Step 4: `roles/bobgpt/tasks/main.yml`**

```yaml
---
# A system account: no login, no home of its own. It needs group ml to read
# the checkpoint tree, and nothing else.
- name: Create the bobgpt service user
  ansible.builtin.user:
    name: "{{ bobgpt_user }}"
    system: true
    create_home: false
    shell: /usr/sbin/nologin
    groups: ml
    append: true

# Owned by robertcowher, not by the service user, so `git pull` and
# `pip install` from deploy.sh need no sudo at all. setgid so everything
# created inside stays in group ml and the service can read it.
- name: Create the bobgpt tree
  ansible.builtin.file:
    path: "{{ bobgpt_root }}"
    state: directory
    owner: robertcowher
    group: ml
    mode: "2775"

- name: Install the host facts file
  ansible.builtin.template:
    src: host.env.j2
    dest: /etc/bobgpt/host.env
    owner: root
    group: root
    mode: "0644"
  notify: Restart bobgpt if running

# update: false is load-bearing. deploy.sh owns the checkout after this; an
# updating clone would revert a pull, or fight a branch switch, on every apply.
- name: Bootstrap the checkout
  ansible.builtin.git:
    repo: "{{ bobgpt_repo }}"
    dest: "{{ bobgpt_root }}/src"
    version: "{{ bobgpt_branch }}"
    update: false
  become: true
  become_user: robertcowher

- name: Install the service unit
  ansible.builtin.template:
    src: bobgpt.service.j2
    dest: /etc/systemd/system/bobgpt.service
    owner: root
    group: root
    mode: "0644"
  notify: Restart bobgpt if running

# enabled: false, deliberately and permanently. Robert starts this by hand;
# it is a GPU service on a box whose GPUs exist for training, and it powers
# off with the host every night.
- name: Install the unit without enabling it
  ansible.builtin.systemd_service:
    name: bobgpt.service
    enabled: false
    daemon_reload: true
```

Handler, `roles/bobgpt/handlers/main.yml`:

```yaml
---
# Only if it is already running. Starting it here would defeat the decision
# not to autostart, and `state: restarted` would start a stopped service.
- name: Restart bobgpt if running
  ansible.builtin.systemd_service:
    name: bobgpt.service
    state: restarted
  when: "'bobgpt.service' in ansible_facts.services | default({})
         and ansible_facts.services['bobgpt.service'].state == 'running'"
```

- [ ] **Step 5: Apply and confirm**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags bobgpt
ssh lab.local 'systemctl is-enabled bobgpt; cat /etc/bobgpt/host.env; ls /opt/bobgpt/src | head'
```
Expected: `disabled`; the env file rendered; the checkout present.

- [ ] **Step 6: Commit**

```bash
git add roles/bobgpt hosts/lab/vars.yml hosts/lab/main.yml
git commit -m "feat(bobgpt): provision the host for a repo-owned bobgpt server"
```

---

### Task 4: The second Open WebUI upstream

**Files:**
- Modify: `roles/webstack/templates/docker-compose.yml.j2`
- Modify: `hosts/lab/vars.yml`

- [ ] **Step 1: Confirm the variable names against the running image**

Do not trust the plural names from memory. Read them off the container:

```bash
ssh lab.local 'docker exec open-webui env | grep -i openai; docker exec open-webui python -c "
from open_webui.config import OPENAI_API_BASE_URLS, OPENAI_API_KEYS
print(OPENAI_API_BASE_URLS.value, OPENAI_API_KEYS.value)" 2>&1 | tail -3'
```

If `OPENAI_API_BASE_URLS` is not accepted, fall back to a Caddy route that
merges both upstreams under one base URL, and record why in the RUNBOOK.

- [ ] **Step 2: Implement**

Replace the two singular lines in the `open-webui` service with:

```yaml
      # Two upstreams, semicolon-separated, and the lists must be the same
      # length. llama-swap first so it stays the default. bobgpt is reached on
      # the host, not in this network, hence host.docker.internal again.
      - OPENAI_API_BASE_URLS=http://host.docker.internal:8080/v1;http://host.docker.internal:{{ bobgpt_port }}/v1
      - OPENAI_API_KEYS=none;none
```

- [ ] **Step 3: Apply and confirm the dropdown is still populated**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags webstack
ssh lab.local 'docker exec open-webui env | grep OPENAI_API_BASE_URLS'
```

Open WebUI must still list the llama-swap models. A bobgpt entry appears only
once the service is started and `serve.sh` exists.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(webstack): add bobgpt as a second Open WebUI upstream"
```

---

### Task 5: Verification

**Files:**
- Modify: `hosts/lab/verify.yml`

- [ ] **Step 1: Add the assertions**

```yaml
    - name: Read the bobgpt unit state
      ansible.builtin.command: systemctl is-enabled bobgpt.service
      register: bobgpt_enabled_state
      changed_when: false
      failed_when: false
      tags: [bobgpt]

    # Not enabled, deliberately. Asserted as the inverse case as well -- that a
    # disabled unit is actually stopped -- because this repo has twice shipped a
    # check that passed while a handler had quietly re-armed the thing it was
    # meant to be guarding.
    - name: bobgpt does not start at boot
      ansible.builtin.assert:
        that:
          - bobgpt_enabled_state.stdout == 'disabled'
        fail_msg: >-
          bobgpt.service is "{{ bobgpt_enabled_state.stdout }}", not disabled.
          It is a GPU service on a box whose GPUs exist for training, and it
          must be started by hand.
      tags: [bobgpt]

    - name: Read the host facts file
      ansible.builtin.slurp:
        src: /etc/bobgpt/host.env
      register: bobgpt_env
      tags: [bobgpt]

    - name: The host facts file names the checkpoint root and port
      ansible.builtin.assert:
        that:
          - "'BOBGPT_CHECKPOINT_ROOT=' ~ bobgpt_checkpoint_root in (bobgpt_env.content | b64decode)"
          - "'BOBGPT_PORT=' ~ bobgpt_port | string in (bobgpt_env.content | b64decode)"
      tags: [bobgpt]

    # The service user must be able to READ the weights and must not be able to
    # write them. A training run's checkpoint is not something a web service
    # should be one bug away from truncating.
    - name: The service user can read the checkpoints but not write them
      ansible.builtin.command: >-
        sudo -u {{ bobgpt_user }} test -r {{ bobgpt_checkpoint_root }}
        -a ! -w {{ bobgpt_checkpoint_root }}
      changed_when: false
      tags: [bobgpt]

    - name: Check for the repo-owned entrypoint
      ansible.builtin.stat:
        path: "{{ bobgpt_root }}/src/serve.sh"
      register: bobgpt_entrypoint
      tags: [bobgpt]

    # A warning, not a failure: the entrypoint belongs to the bobgptv1
    # repository, and the host is correctly provisioned whether or not that
    # repository has caught up yet. Without this the only symptom is
    # systemd's status=203/EXEC, which names nothing useful.
    - name: Warn if the repository has not supplied serve.sh yet
      ansible.builtin.debug:
        msg: >-
          {{ bobgpt_root }}/src/serve.sh is missing or not executable, so
          `systemctl start bobgpt` will fail with 203/EXEC. The host is ready;
          bobgptv1 needs to provide an executable serve.sh that listens on
          $BOBGPT_HOST:$BOBGPT_PORT. Facts are in /etc/bobgpt/host.env.
      when: not (bobgpt_entrypoint.stat.exists and bobgpt_entrypoint.stat.xusr | default(false))
      tags: [bobgpt]
```

- [ ] **Step 2: Run the full verify**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```
Expected: `failed=0`, with the serve.sh warning shown.

- [ ] **Step 3: Commit**

```bash
git commit -am "test(bobgpt): assert the host contract, and warn on a missing entrypoint"
```

---

### Task 6: Document it

**Files:**
- Modify: `docs/RUNBOOK.md`

- [ ] **Step 1: Add a `## bobgpt` section** covering: what it is and that it is
  started by hand (`sudo systemctl start bobgpt`); the contract table from this
  plan; that `deploy.sh` in the repository owns pulls and dependencies while
  Ansible owns only `/etc/bobgpt/host.env`; how it interacts with the overnight
  poweroff (excluded from the GPU signal by cgroup, but active use vetoes); and
  the 3060 contention note about `gemma-4-12b`. Add the Contents entry.

- [ ] **Step 2: Commit**

```bash
git commit -am "docs: how bobgpt is deployed, and who owns which half"
```
