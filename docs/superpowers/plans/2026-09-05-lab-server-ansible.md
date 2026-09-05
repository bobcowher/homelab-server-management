# Lab Server Ansible — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure `lab` (192.168.1.30) declaratively with Ansible so the host can be rebuilt without hand-reconstructing users, permissions, GPU plumbing, or services.

**Architecture:** Roles are a shared library at the top level; `hosts/lab/main.yml` composes them for this one host. Each role is developed test-first: its assertions go into `hosts/lab/verify.yml` and must fail before the role is written. Idempotency is a first-class test — every role must report `changed=0` on a second run.

**Tech Stack:** ansible-core 2.16.3, `community.general` 8.3.0, `ansible.posix` 1.5.4. Ubuntu 26.04.1 (`resolute`), LVM, Docker CE, NVIDIA 595-server-open, Miniforge, Caddy, ufw + iptables `DOCKER-USER`.

**Spec:** `docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md`

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Target host:** `lab` / `192.168.1.30`, Ubuntu 26.04.1 LTS, codename `resolute`, kernel 7.0.0-31-generic, interface `enp5s0`.
- **`robertcowher` has passwordless sudo** via `/etc/sudoers.d/robertcowher-nopasswd`, managed by the `users` role. Decided 2026-09-05: the account is already in the `docker` group, which is root-equivalent without a password, so requiring one on sudo was not an actual boundary. Runs therefore need no `--ask-become-pass`.
- **Nothing is exposed to the internet.** All LAN rules are scoped to `192.168.1.0/24`.
- **Numeric IDs are fixed and load-bearing:** `ml`=3000, `robertcowher`=1000, `beekeeper`=2001, `llm`=2002, `files`=2003. These live in `group_vars/all.yml` and exist in exactly one place. `/data` ownership survives a rebuild only because they never change.
- **Pinned versions:** NVIDIA driver branch `595-server`; llama-swap `253` (sha256 `91f4d0af56cd5471d0133d6f89db7a7db118a9cd6f8ecd2bbdffd50aa29e5eb6`); conda env `beekeeper` at Python `3.12`.
- **Apt holds:** `nvidia-*`, `docker-ce*`, `containerd*`. Unattended-upgrades is scoped to `resolute` security origins only.
- **No containerized service may listen on a LAN address.** Only Caddy (`:80`) and native services (`22`, `8080`, `5000`) are LAN-reachable.
- **Do NOT implement anything in spec §10 (Deferred):** no Tailscale, no restic repos/timers/credentials, no `disk-check.timer`. `restic` is installed as a package and left unconfigured, deliberately.
- **Every role is tagged with its own name** so it can be run and verified in isolation.

---

## Prerequisites

Complete before Task 1. These are not tasks; they gate the whole plan.

- [x] **Server is up and every premise re-validated against it (2026-09-05).** Release, kernel, interface, absent packages, and the LVM layout all match section 2 of the spec. Confirmed unprivileged: `nvme0n1p3` is 1,997,122,043,904 bytes against a 107,374,182,400 byte LV, so ~1.72TiB is still unallocated and Task 4's premise holds.
- [ ] Install `ansible-lint` (not currently present): `pipx install ansible-lint` or `sudo apt install ansible-lint`.
- [ ] Confirm SSH key auth still works: `ssh robertcowher@lab.local true`.
- [x] Passwordless sudo installed for `robertcowher` (2026-09-05). No `--ask-become-pass` needed.

---

## The Test Cycle for Ansible

The classic red/green cycle maps onto config management, but the "test" is
two things rather than one. Every role task follows this shape:

1. Add the role's assertions to `hosts/lab/verify.yml` under its tag.
2. Run verify → **must FAIL**. If it passes, the assertion is not testing anything.
3. Write the role.
4. Apply the role.
5. **Apply it a second time → `changed=0`.** This is the idempotency test and it catches more real bugs than the assertions do. A role that reports `changed` on every run is broken even when the host is correct.
6. Run verify → **must PASS**.
7. Commit.

`changed=0` proves the tasks ran without re-doing work. It does not prove the
host is correct. The verify assertions do that, which is why they are written
first and live in a separate playbook.

**Commands used throughout** (from the repo root):

```bash
# apply one role
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags <role>

# verify one role
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags <role>

# syntax + lint, no host required
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --syntax-check
ansible-lint hosts/lab/main.yml
```

---

## File Structure

```
ansible.cfg                     # inventory path, become defaults, ssh pipelining
requirements.yml                # collection pins
inventory/hosts.yml             # every host
inventory/group_vars/all.yml    # fleet invariants ONLY: uid/gid map, lan_subnet
                                # MUST live beside the inventory: a repo-root
                                # group_vars/ is NOT loaded for a playbook at
                                # hosts/lab/, and every UID silently vanishes
hosts/lab/main.yml              # this host's playbook: its roles, in order, tagged
hosts/lab/vars.yml              # host specifics: driver branch, versions, tool lists
hosts/lab/verify.yml            # host-specific end-state assertions, tagged per role
roles/base/tasks/main.yml
roles/users/tasks/main.yml
roles/storage/tasks/main.yml
roles/nvidia/tasks/main.yml
roles/docker/tasks/main.yml
roles/firewall/tasks/main.yml
roles/firewall/templates/docker-user-rules.sh.j2
roles/firewall/templates/docker-user-rules.service.j2
roles/conda/tasks/main.yml
roles/conda/templates/conda.sh.j2
roles/tools/tasks/main.yml
roles/llama_swap/tasks/main.yml
roles/llama_swap/templates/llama-swap.service.j2
roles/llama_swap/templates/config.yaml.j2
roles/webstack/tasks/main.yml
roles/webstack/templates/docker-compose.yml.j2
roles/webstack/templates/Caddyfile.j2
roles/webstack/templates/docker-compose@.service.j2
roles/beekeeper/tasks/main.yml
roles/beekeeper/templates/beekeeper-sudoers.j2
```

---

## Five Ways This Plan Can Break the Host

Read these before writing any role. Each is handled by a specific step, and
each is a way to lose access to a headless machine.

1. **ufw lockout.** Enabling ufw before allowing port 22 disconnects you permanently. Task 7 allows 22 *first*, in a prior task, then enables.
2. **sudoers lockout.** A malformed file in `/etc/sudoers.d/` breaks `sudo` for *everyone*, including `robertcowher`. Task 12 uses `validate: /usr/sbin/visudo -cf %s`, which refuses to install a file that does not parse.
3. **sshd lockout.** A bad `sshd_config` plus a restart ends the session and every future one. Task 2 uses `validate: /usr/sbin/sshd -t -f %s`.
4. **Driver replacement.** Installing `nvidia-utils-595-server` must not pull a different driver branch; a mismatch between the userspace libs and the loaded kernel module breaks every GPU workload until reboot. Task 5 dry-runs apt and asserts nothing is being removed.
5. **LVM extend is one-way.** Growing the root LV cannot be undone without a restore. Task 4 captures pre-state and asserts free extents exist before touching anything.

---

## Task 1: Repo skeleton and connectivity

**Files:**
- Create: `ansible.cfg`, `requirements.yml`, `inventory/hosts.yml`, `group_vars/all.yml`, `hosts/lab/vars.yml`, `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: variables `ml_gid`, `user_uids` (dict name→uid), `lan_subnet`, `data_root`, `wan_interface`, `nvidia_driver_branch`, `llama_swap_version`, `llama_swap_sha256`, `conda_prefix`, `conda_envs`, `tools_apt`, `tools_pipx`, `beekeeper_branch`, `beekeeper_home`, `apt_holds`, `lab_users`. Every later task reads these.

- [ ] **Step 1: Write the failing test — a verify playbook that asserts the host is reachable and identified correctly**

`hosts/lab/verify.yml`:

```yaml
---
- name: Verify lab end state
  hosts: lab
  gather_facts: true
  vars_files:
    - vars.yml

  tasks:
    - name: Host is the expected Ubuntu release
      ansible.builtin.assert:
        that:
          - ansible_distribution == 'Ubuntu'
          - ansible_distribution_version is version('26.04', '>=')
          - ansible_lsb.codename == 'resolute'
        fail_msg: >-
          Expected Ubuntu 26.04 (resolute), got
          {{ ansible_distribution }} {{ ansible_distribution_version }}
      tags: [always]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml`
Expected: FAIL — `inventory/hosts.yml` does not exist yet, so the host pattern `lab` matches nothing (or errors on a missing inventory file).

- [ ] **Step 3: Write `ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
host_key_checking = True
stdout_callback = yaml
interpreter_python = auto_silent
nocows = True

[ssh_connection]
pipelining = True
```

- [ ] **Step 4: Write `requirements.yml`**

```yaml
---
collections:
  - name: community.general
    version: ">=8.3.0"
  - name: ansible.posix
    version: ">=1.5.4"
```

- [ ] **Step 5: Write `inventory/hosts.yml`**

```yaml
---
all:
  hosts:
    lab:
      ansible_host: 192.168.1.30
      ansible_user: robertcowher
```

- [ ] **Step 6: Write `inventory/group_vars/all.yml` — fleet invariants only**

Path matters. Ansible auto-loads `group_vars/` from beside the *inventory
file* or beside the *playbook*. This playbook lives at `hosts/lab/main.yml`,
so a repo-root `group_vars/` is loaded by neither — `ml_gid` and `user_uids`
come back undefined with no error, and the users role would create accounts at
whatever UID the system picks. Verified empirically during execution.

```yaml
---
# Fleet invariants. The test for what belongs here: if a second lab server
# would have to agree on it, it is fleet-wide.
#
# These numeric IDs are load-bearing. /data ownership survives a rebuild only
# because they never change, and a restore onto a host where they differ
# silently produces wrong ownership. Do not edit without a migration plan.

ml_gid: 3000

user_uids:
  robertcowher: 1000
  beekeeper: 2001
  llm: 2002
  files: 2003

lan_subnet: 192.168.1.0/24
```

- [ ] **Step 7: Write `hosts/lab/vars.yml` — everything host-specific**

```yaml
---
wan_interface: enp5s0
data_root: /data

lab_users:
  - name: robertcowher
    shell: /bin/bash
    groups: [ml, docker, sudo]
  - name: beekeeper
    shell: /bin/bash
    groups: [ml]
  - name: llm
    shell: /usr/sbin/nologin
    groups: [ml, docker]
  - name: files
    shell: /usr/sbin/nologin
    groups: []

nvidia_driver_branch: 595-server

apt_holds:
  - nvidia-*
  - docker-ce*
  - containerd*

conda_prefix: /opt/conda
conda_envs:
  # beekeeper: the service environment. setup.sh finds python3.12 here.
  - name: beekeeper
    python: "3.12"
  # py312: general-purpose 3.12 for interactive work. Read-only like every
  # shared env; to install into it, clone it first:
  #   conda create -n mywork --clone py312
  # which lands in ~/.conda/envs and is writable.
  - name: py312
    python: "3.12"

tools_apt:
  - htop
  - nvtop
  - iotop
  - ncdu
  - tree
  - ripgrep
  - fd-find
  - pciutils
  - sysstat
  - tmux
  - jq
  - unzip
  - nvme-cli
  - smartmontools

tools_pipx:
  - nvitop

llama_swap_version: "253"
llama_swap_sha256: 91f4d0af56cd5471d0133d6f89db7a7db118a9cd6f8ecd2bbdffd50aa29e5eb6

# deploy.sh resets the checkout to origin/develop, so Ansible clones the same
# branch to avoid the two fighting. Change here if that ever moves to main.
beekeeper_branch: develop
beekeeper_home: /home/beekeeper/beekeeper
```

- [ ] **Step 8: Write `hosts/lab/main.yml` with no roles yet**

```yaml
---
- name: Configure lab
  hosts: lab
  become: true
  gather_facts: true
  vars_files:
    - vars.yml

  roles: []
```

- [ ] **Step 9: Run the verify playbook to confirm it now passes**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml`
Expected: PASS. If it fails on the codename, stop — the host is not what the spec describes and every downstream assumption needs rechecking.

- [ ] **Step 10: Confirm syntax and lint are clean**

Run:
```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --syntax-check
ansible-lint hosts/lab/main.yml hosts/lab/verify.yml
```
Expected: no errors.

- [ ] **Step 11: Commit**

```bash
git add ansible.cfg requirements.yml inventory hosts
git commit -m "feat: ansible skeleton, inventory, and fleet/host variable split"
```

---

## Task 2: `base` role

**Files:**
- Create: `roles/base/tasks/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: nothing from earlier roles.
- Produces: `restic`, `git`, `curl`, `build-essential`, `ca-certificates` present for later roles. Unattended-upgrades scoped so Task 5's apt holds are not fought by automatic upgrades.

- [ ] **Step 1: Write the failing assertions**

Append to the `tasks:` list in `hosts/lab/verify.yml`:

```yaml
    - name: Base packages are installed
      ansible.builtin.command: dpkg-query -W -f='${Status}' {{ item }}
      register: base_pkg
      changed_when: false
      # 'hold ok installed' also means installed; the nvidia role's apt-holds
      # change dpkg's first status field, so match only the parts that mean
      # the package is present.
      failed_when: "'ok installed' not in base_pkg.stdout"
      loop:
        - build-essential
        - git
        - curl
        - ca-certificates
        - restic
        - unattended-upgrades
      tags: [base]

    - name: Unattended-upgrades is scoped to resolute security origins only
      ansible.builtin.slurp:
        src: /etc/apt/apt.conf.d/50unattended-upgrades
      register: uu_conf
      tags: [base]

    - name: Unattended-upgrades does not pull non-security updates
      ansible.builtin.assert:
        that:
          - "'${distro_id}:${distro_codename}-security' in (uu_conf.content | b64decode)"
          - "'\"${distro_id}:${distro_codename}-updates\";' not in (uu_conf.content | b64decode)"
        fail_msg: >-
          unattended-upgrades would move packages outside the security pocket,
          which will break the pinned NVIDIA driver.
      tags: [base]

    # Ubuntu 26.04 has no /etc/timezone; systemd owns this via the
    # /etc/localtime symlink, so ask timedatectl rather than read a file.
    - name: Read the configured timezone
      ansible.builtin.command: timedatectl show -p Timezone --value
      register: tz_conf
      changed_when: false
      tags: [base]

    - name: Timezone matches the declared value
      ansible.builtin.assert:
        that:
          - tz_conf.stdout | trim == timezone
        fail_msg: "Timezone is {{ tz_conf.stdout | trim }}, expected {{ timezone }}"
      tags: [base]
```

- [ ] **Step 2: Run verify to confirm it fails**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags base`
Expected: FAIL — `restic` and `unattended-upgrades` are not installed, and the origins are at defaults.

- [ ] **Step 3: Write `roles/base/tasks/main.yml`**

```yaml
---
- name: Set timezone
  community.general.timezone:
    name: "{{ timezone }}"

- name: Update apt cache
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 3600

- name: Install base packages
  ansible.builtin.apt:
    name:
      - build-essential
      - git
      - curl
      - ca-certificates
      - gnupg
      - restic
      - unattended-upgrades
      - python3-apt
    state: present

# restic is installed but deliberately left unconfigured. Backups are a
# deferred decision (spec section 10). Do not add repos, timers, or
# credentials here without being asked.

- name: Scope unattended-upgrades to security origins only
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root
    group: root
    mode: "0644"
    content: |
      // Managed by Ansible. Security pocket only: a broader scope would move
      // the NVIDIA driver out from under the container toolkit and break
      // every GPU container without warning (spec 3.6).
      Unattended-Upgrade::Allowed-Origins {
          "${distro_id}:${distro_codename}-security";
          "${distro_id}ESMApps:${distro_codename}-apps-security";
          "${distro_id}ESM:${distro_codename}-infra-security";
      };
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
      Unattended-Upgrade::Automatic-Reboot "false";

- name: Enable unattended-upgrades periodic runs
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root
    group: root
    mode: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

- name: Harden sshd
  ansible.builtin.copy:
    dest: /etc/ssh/sshd_config.d/10-lab.conf
    owner: root
    group: root
    mode: "0644"
    validate: /usr/sbin/sshd -t -f %s
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      X11Forwarding no
  notify: Reload sshd
```

The `validate` on the sshd drop-in is not optional. Without it, a typo plus
the handler below ends the session and every future one.

- [ ] **Step 4: Write `roles/base/handlers/main.yml`**

```yaml
---
- name: Reload sshd
  ansible.builtin.systemd_service:
    name: ssh
    state: reloaded
```

Reload, not restart: a reload keeps existing connections alive, so a
configuration that somehow got past `sshd -t` still leaves you logged in.

- [ ] **Step 5: Add the role to the playbook**

In `hosts/lab/main.yml`, replace `roles: []` with:

```yaml
  roles:
    - { role: base, tags: [base] }
```

- [ ] **Step 6: Apply the role**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags base`
Expected: several `changed` tasks, no failures.

- [ ] **Step 7: Apply again to test idempotency**

Run the same command.
Expected: `changed=0`. If `Set timezone` or either apt.conf file reports changed on the second run, the content is not stable — fix before continuing.

- [ ] **Step 8: Run verify**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags base`
Expected: PASS.

- [ ] **Step 9: Confirm SSH still works from a NEW connection**

Run: `ssh -o ControlPath=none robertcowher@lab.local true; echo "exit=$?"`
Expected: `exit=0`. Do this before committing — the existing Ansible connection
may be multiplexed and would mask a broken sshd config.

- [ ] **Step 10: Commit**

```bash
git add roles/base hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(base): apt essentials, scoped unattended-upgrades, sshd hardening"
```

---

## Task 3: `users` role

**Files:**
- Create: `roles/users/tasks/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `ml_gid`, `user_uids`, `lab_users`.
- Produces: group `ml` at GID 3000 and the four accounts at their fixed UIDs. Task 4 depends on these existing before it creates `/data`, or the directories get wrong ownership.

Note: the `docker` group does not exist yet — Task 6 creates it. Group
membership is therefore applied in two passes: this role creates users without
`docker`, and Task 6 adds the `docker` group members after installing Docker.
Attempting it here fails with "group docker does not exist".

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Read group file
      ansible.builtin.getent:
        database: group
        key: ml
      tags: [users]

    - name: ml group has the exact fleet GID
      ansible.builtin.assert:
        that:
          - getent_group['ml'][1] | int == ml_gid
        fail_msg: >-
          ml GID is {{ getent_group['ml'][1] }}, expected {{ ml_gid }}.
          A drifted GID breaks /data ownership on restore.
      tags: [users]

    - name: Read each managed user
      ansible.builtin.getent:
        database: passwd
        key: "{{ item.name }}"
      register: user_ent
      loop: "{{ lab_users }}"
      loop_control:
        label: "{{ item.name }}"
      tags: [users]

    - name: The passwordless sudo drop-in parses
      ansible.builtin.command: /usr/sbin/visudo -cf /etc/sudoers.d/robertcowher-nopasswd
      become: true
      register: rc_sudoers
      changed_when: false
      tags: [users]

    - name: Each user has the exact fleet UID and expected shell
      ansible.builtin.assert:
        that:
          - item.ansible_facts.getent_passwd[item.item.name][1] | int
            == user_uids[item.item.name]
          - item.ansible_facts.getent_passwd[item.item.name][5]
            == item.item.shell
        fail_msg: >-
          {{ item.item.name }} has UID
          {{ item.ansible_facts.getent_passwd[item.item.name][1] }} /
          shell {{ item.ansible_facts.getent_passwd[item.item.name][5] }},
          expected {{ user_uids[item.item.name] }} / {{ item.item.shell }}
      loop: "{{ user_ent.results }}"
      loop_control:
        label: "{{ item.item.name }}"
      tags: [users]
```

- [ ] **Step 2: Run verify to confirm it fails**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags users`
Expected: FAIL — the `ml` group does not exist, so the getent lookup returns nothing.

- [ ] **Step 3: Write `roles/users/tasks/main.yml`**

```yaml
---
- name: Create the ml group at its fixed GID
  ansible.builtin.group:
    name: ml
    gid: "{{ ml_gid }}"
    state: present

- name: Create managed users at their fixed UIDs
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ user_uids[item.name] }}"
    shell: "{{ item.shell }}"
    create_home: true
    # 'docker' is filtered out here because Task 6 creates that group. It is
    # added back by the docker role, which runs later.
    groups: "{{ item.groups | difference(['docker']) }}"
    append: true
    state: present
  loop: "{{ lab_users }}"
  loop_control:
    label: "{{ item.name }}"

- name: Grant robertcowher passwordless sudo
  ansible.builtin.copy:
    dest: /etc/sudoers.d/robertcowher-nopasswd
    owner: root
    group: root
    mode: "0440"
    content: "robertcowher ALL=(ALL) NOPASSWD: ALL\n"
    # Managed here so a rebuild reproduces it rather than depending on someone
    # having run a command by hand. Smaller grant than it appears: robertcowher
    # is in the docker group, already root-equivalent with no password via
    # `docker run -v /:/host`.
    #
    # validate is mandatory. A parse error under /etc/sudoers.d breaks sudo for
    # every user, and this playbook has no other route to root.
    validate: /usr/sbin/visudo -cf %s
```

`append: true` matters: without it a re-run strips any group a human added by
hand, which is a silent way to lose access.

- [ ] **Step 4: Add to the playbook, after `base`**

```yaml
  roles:
    - { role: base, tags: [base] }
    - { role: users, tags: [users] }
```

- [ ] **Step 5: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags users`
Expected: `changed` for the group and for `beekeeper`, `llm`, `files`. `robertcowher` already exists at UID 1000 and should report `ok` or a small change for group membership only.

- [ ] **Step 6: Apply again**

Expected: `changed=0`.

- [ ] **Step 7: Run verify**

Expected: PASS, with the UID assertions checking the numbers rather than mere existence.

- [ ] **Step 8: Commit**

```bash
git add roles/users hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(users): ml group and four accounts at fixed numeric IDs"
```

---

## Task 4: `storage` role

**Files:**
- Create: `roles/storage/tasks/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `data_root`, `ml_gid`, `user_uids`.
- Produces: root filesystem grown to fill the VG; `/data/models`, `/data/datasets`, `/data/beekeeper` owned `root:ml` with setgid. Tasks 10 and 12 write into these.

**This is the only destructive-capable role in the playbook.** Growing an LV
cannot be undone without a restore. Online ext4 growth is routine and safe, but
it is one-way.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Collect volume group state
      ansible.builtin.command: vgs --noheadings -o vg_free --units b --nosuffix ubuntu-vg
      register: vg_free
      changed_when: false
      tags: [storage]

    - name: Volume group has been fully allocated
      ansible.builtin.assert:
        that:
          - vg_free.stdout | trim | int < 33554432
        fail_msg: >-
          ubuntu-vg still has {{ vg_free.stdout | trim | int // 1073741824 }}GB
          unallocated; the root LV was not extended.
      tags: [storage]

    - name: Root filesystem is larger than the installer default
      ansible.builtin.assert:
        that:
          - (ansible_mounts | selectattr('mount', 'eq', '/') | first).size_total
            > 214748364800
        fail_msg: Root filesystem is still at or below the 100GB install default.
      tags: [storage]

    - name: Collect /data directory state
      ansible.builtin.stat:
        path: "{{ item }}"
      register: data_dirs
      loop:
        - "{{ data_root }}"
        - "{{ data_root }}/models"
        - "{{ data_root }}/datasets"
        - "{{ data_root }}/beekeeper"
      tags: [storage]

    - name: Data directories exist, are group ml, and are setgid
      ansible.builtin.assert:
        that:
          - item.stat.exists
          - item.stat.isdir
          - item.stat.gid | int == ml_gid
          - item.stat.mode == '2775'
        fail_msg: >-
          {{ item.item }} is mode {{ item.stat.mode | default('absent') }}
          gid {{ item.stat.gid | default('n/a') }}; expected mode 2775 gid
          {{ ml_gid }}. Without setgid the shared tree rots as soon as two
          users write to it.
      loop: "{{ data_dirs.results }}"
      loop_control:
        label: "{{ item.item }}"
      tags: [storage]
```

- [ ] **Step 2: Run verify to confirm it fails**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags storage`
Expected: FAIL on the first assertion — roughly 1.7TB is unallocated.

- [ ] **Step 3: Capture pre-state before touching anything**

Run and save the output somewhere outside the repo:

```bash
ssh robertcowher@lab.local 'lsblk; echo ---; sudo vgs; echo ---; sudo lvs; echo ---; df -h /'
```

Expected: `ubuntu-vg/ubuntu-lv` around 100G, roughly 1.7T free in the VG. If
the free space is not there, **stop** — the spec's premise is wrong and the
extend must not run.

- [ ] **Step 4: Write `roles/storage/tasks/main.yml`**

```yaml
---
- name: Read volume group free space
  ansible.builtin.command: vgs --noheadings -o vg_free --units b --nosuffix ubuntu-vg
  register: storage_vg_free
  changed_when: false

- name: Refuse to proceed if the volume group is not what the spec describes
  ansible.builtin.assert:
    that:
      - storage_vg_free.stdout | trim | int >= 0
    fail_msg: >-
      ubuntu-vg not found or unreadable. Do not continue: this role grows a
      filesystem and must not run against an unexpected layout.

- name: Extend the root logical volume to fill the volume group
  community.general.lvol:
    vg: ubuntu-vg
    lv: ubuntu-lv
    size: 100%VG
    resizefs: true

- name: Create the shared data tree
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: ml
    # setgid: files written by llama-swap or beekeeper inherit group ml and
    # stay readable across services. Without it the tree silently rots.
    mode: "2775"
  loop:
    - "{{ data_root }}"
    - "{{ data_root }}/models"
    - "{{ data_root }}/datasets"
    - "{{ data_root }}/beekeeper"
```

`lvol` with `size: 100%VG` is idempotent: once the LV already spans the VG, a
second run reports `ok`.

- [ ] **Step 5: Dry-run the role first**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags storage --check --diff`
Expected: shows the lvol and file tasks as would-change. `--check` cannot fully
simulate `lvol`, so treat this as a sanity read, not a guarantee.

- [ ] **Step 6: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags storage`
Expected: `changed` on the lvol and the four directories.

- [ ] **Step 7: Confirm the filesystem actually grew**

Run: `ssh robertcowher@lab.local 'df -h /; sudo vgs'`
Expected: root around 1.7T, VG free near zero. If `lvs` grew but `df` did not,
`resizefs` did not run — resolve before continuing.

- [ ] **Step 8: Apply again**

Expected: `changed=0`.

- [ ] **Step 9: Run verify**

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add roles/storage hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(storage): extend root LV to fill VG, create setgid /data tree"
```

---

## Task 5: `nvidia` role

**Files:**
- Create: `roles/nvidia/tasks/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `nvidia_driver_branch`, `apt_holds`.
- Produces: `nvidia-smi` on PATH, `nvidia-container-toolkit` installed. Task 6 configures Docker to use the runtime this provides; Task 11's DCGM exporter depends on it.

The driver is already installed and its kernel modules match the running
kernel. Only the userspace utilities are missing. This role must not change
the driver.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: nvidia-smi runs on the host
      ansible.builtin.command: nvidia-smi --query-gpu=name,pci.bus_id --format=csv,noheader
      register: smi
      changed_when: false
      tags: [nvidia]

    - name: Both GPUs are visible
      ansible.builtin.assert:
        that:
          - smi.stdout_lines | length == 2
          - "'3090' in smi.stdout"
          - "'3060' in smi.stdout"
        fail_msg: "Expected an RTX 3090 and an RTX 3060, got: {{ smi.stdout }}"
      tags: [nvidia]

    - name: Container toolkit is installed
      ansible.builtin.command: dpkg-query -W -f='${Status}' nvidia-container-toolkit
      register: nct
      changed_when: false
      # 'hold ok installed' also means installed; the nvidia role's apt-holds
      # change dpkg's first status field, so match only the parts that mean
      # the package is present.
      failed_when: "'ok installed' not in nct.stdout"
      tags: [nvidia]

    - name: Driver packages are held
      ansible.builtin.command: apt-mark showhold
      register: holds
      changed_when: false
      tags: [nvidia]

    - name: NVIDIA and Docker packages are pinned against unattended upgrades
      ansible.builtin.assert:
        that:
          - holds.stdout is search('nvidia')
        fail_msg: >-
          No nvidia package is held. An automatic driver upgrade will break
          every GPU container without warning.
      tags: [nvidia]
```

The in-container `nvidia-smi` check belongs to Task 6, because it needs Docker.

- [ ] **Step 2: Run verify to confirm it fails**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags nvidia`
Expected: FAIL — `nvidia-smi` is not installed.

- [ ] **Step 3: Check what apt intends to do BEFORE installing**

Run:
```bash
ssh robertcowher@lab.local \
  'sudo apt-get install --dry-run nvidia-utils-595-server | grep -E "^(Remv|Inst)"'
```
Expected: `Inst nvidia-utils-595-server` and possibly small library additions.
**If any line starts with `Remv`, or any `Inst` names a different driver
branch, stop.** Installing would desync the userspace libraries from the loaded
kernel module and break every GPU workload until a reboot.

- [ ] **Step 4: Write `roles/nvidia/tasks/main.yml`**

```yaml
---
- name: Install the driver utilities that supply nvidia-smi
  ansible.builtin.apt:
    name: "nvidia-utils-{{ nvidia_driver_branch }}"
    state: present
    # The driver itself is already installed and module-matched to the running
    # kernel. Only the userspace utilities are missing (spec 2, 4).

- name: Create the apt keyring directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Fetch the NVIDIA container toolkit signing key
  ansible.builtin.get_url:
    url: https://nvidia.github.io/libnvidia-container/gpgkey
    dest: /etc/apt/keyrings/nvidia-container-toolkit.asc
    owner: root
    group: root
    mode: "0644"

- name: Add the container toolkit repository
  ansible.builtin.deb822_repository:
    name: nvidia-container-toolkit
    types: [deb]
    # This repo is distro-independent, so it cannot lag a new Ubuntu release
    # the way a codename-scoped repo would (spec 5.4).
    uris: https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH)
    suites: ["/"]
    signed_by: /etc/apt/keyrings/nvidia-container-toolkit.asc
    state: present
    enabled: true
  notify: Update apt cache

- name: Flush the repository change before installing from it
  ansible.builtin.meta: flush_handlers

- name: Install the container toolkit
  ansible.builtin.apt:
    name: nvidia-container-toolkit
    state: present
    update_cache: true
    # Absent from Ubuntu's own repositories by design.

- name: Hold packages against automatic upgrades
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop: "{{ nvidia_held_packages }}"
  vars:
    nvidia_held_packages: >-
      {{ ansible_facts.packages.keys() | select('match', '^(nvidia|docker-ce|containerd)')
         | list }}
  when: ansible_facts.packages is defined
```

The hold task needs the package facts. Add this as the first task in the file:

```yaml
- name: Gather installed package facts
  ansible.builtin.package_facts:
    manager: apt
```

- [ ] **Step 5: Write `roles/nvidia/handlers/main.yml`**

```yaml
---
- name: Update apt cache
  ansible.builtin.apt:
    update_cache: true
```

- [ ] **Step 6: Add to the playbook, after `storage`**

```yaml
    - { role: nvidia, tags: [nvidia] }
```

- [ ] **Step 7: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags nvidia`

- [ ] **Step 8: Confirm the driver did not change**

Run: `ssh robertcowher@lab.local 'nvidia-smi; cat /proc/driver/nvidia/version'`
Expected: both GPUs listed, and the kernel module version still 595. If
`nvidia-smi` reports a driver/library mismatch, the userspace packages moved
and the host needs a reboot.

- [ ] **Step 9: Apply again**

Expected: `changed=0`. The `dpkg_selections` loop reports `ok` once the holds exist.

- [ ] **Step 10: Run verify**

Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add roles/nvidia hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(nvidia): nvidia-smi, container toolkit repo, apt holds on driver"
```

---

## Task 6: `docker` role

**Files:**
- Create: `roles/docker/tasks/main.yml`, `roles/docker/handlers/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `lab_users`, `nvidia` role's toolkit.
- Produces: `docker` group, `docker compose` plugin, nvidia runtime registered in `daemon.json`, and the `DOCKER-USER` iptables chain that Task 7 writes rules into. Adds `docker` group membership deferred from Task 3.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Docker daemon is active
      ansible.builtin.systemd_service:
        name: docker
      register: dockersvc
      changed_when: false
      tags: [docker]

    - name: Docker is running and enabled
      ansible.builtin.assert:
        that:
          - dockersvc.status.ActiveState == 'active'
          - dockersvc.status.UnitFileState == 'enabled'
        fail_msg: "Docker is {{ dockersvc.status.ActiveState }}"
      tags: [docker]

    - name: Compose plugin is present
      ansible.builtin.command: docker compose version
      register: composev
      changed_when: false
      tags: [docker]

    - name: GPUs are visible inside a container
      ansible.builtin.command: >-
        docker run --rm --gpus all
        nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
      register: cuda_smi
      changed_when: false
      tags: [docker]

    - name: Both GPUs are passed through to containers
      ansible.builtin.assert:
        that:
          - cuda_smi.stdout_lines | length == 2
        fail_msg: >-
          Container sees {{ cuda_smi.stdout_lines | length }} GPU(s).
          Package-installed is not proof; this is (spec 5.4).
      tags: [docker]

    - name: Users who need docker are in the docker group
      ansible.builtin.getent:
        database: group
        key: docker
      tags: [docker]

    - name: robertcowher and llm can reach the docker socket
      ansible.builtin.assert:
        that:
          - "'robertcowher' in getent_group['docker'][2]"
          - "'llm' in getent_group['docker'][2]"
        fail_msg: >-
          docker group members are {{ getent_group['docker'][2] }};
          llama-swap runs as llm and spawns backend containers.
      tags: [docker]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — Docker is not installed.

- [ ] **Step 3: Write `roles/docker/tasks/main.yml`**

```yaml
---
- name: Fetch the Docker signing key
  ansible.builtin.get_url:
    url: https://download.docker.com/linux/ubuntu/gpg
    dest: /etc/apt/keyrings/docker.asc
    owner: root
    group: root
    mode: "0644"

- name: Add the Docker repository
  ansible.builtin.deb822_repository:
    name: docker
    types: [deb]
    uris: https://download.docker.com/linux/ubuntu
    # 'resolute' is published upstream; verified during design.
    suites: ["{{ ansible_lsb.codename }}"]
    components: [stable]
    signed_by: /etc/apt/keyrings/docker.asc
    state: present
    enabled: true

- name: Install Docker CE and the compose plugin
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present
    update_cache: true

- name: Configure the daemon
  ansible.builtin.copy:
    dest: /etc/docker/daemon.json
    owner: root
    group: root
    mode: "0644"
    content: |
      {
        "runtimes": {
          "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
          }
        },
        "log-driver": "json-file",
        "log-opts": {
          "max-size": "50m",
          "max-file": "3"
        }
      }
  notify: Restart docker

- name: Start and enable Docker
  ansible.builtin.systemd_service:
    name: docker
    state: started
    enabled: true

- name: Add the deferred docker group memberships
  ansible.builtin.user:
    name: "{{ item.name }}"
    groups: [docker]
    append: true
  loop: "{{ lab_users | selectattr('groups', 'contains', 'docker') | list }}"
  loop_control:
    label: "{{ item.name }}"
  # docker group membership is root-equivalent. It is granted deliberately to
  # robertcowher and to llm, which spawns backend containers (spec 5.2).
```

Log rotation is not cosmetic here: vLLM containers are chatty and their logs
now share a filesystem with the OS.

- [ ] **Step 4: Write `roles/docker/handlers/main.yml`**

```yaml
---
- name: Restart docker
  ansible.builtin.systemd_service:
    name: docker
    state: restarted
```

- [ ] **Step 5: Add to the playbook, after `nvidia`**

```yaml
    - { role: docker, tags: [docker] }
```

- [ ] **Step 6: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags docker`

- [ ] **Step 7: Apply again**

Expected: `changed=0`.

- [ ] **Step 8: Run verify**

Expected: PASS, including the in-container `nvidia-smi -L` listing two GPUs.
This is the real proof that Task 5 worked; a successful package install is not.

- [ ] **Step 9: Commit**

```bash
git add roles/docker hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(docker): docker-ce, nvidia runtime, log rotation, group membership"
```

---

## Task 7: `firewall` role

**Files:**
- Create: `roles/firewall/tasks/main.yml`, `roles/firewall/templates/docker-user-rules.sh.j2`, `roles/firewall/templates/docker-user-rules.service.j2`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `lan_subnet`, `wan_interface`, and the `DOCKER-USER` chain created by Task 6.
- Produces: the enforcement boundary the whole bind policy rests on. Task 11 publishes Caddy on `:80` and relies on the `DOCKER-USER` rules written here.

**This is the subtlest role in the plan.** Two things make it so.

**First: ufw cannot protect containers.** Docker writes to the `nat` PREROUTING
and `FORWARD` chains, which are evaluated before ufw's INPUT rules. A container
published with `-p 3000:3000` is LAN-reachable even under
`ufw default deny incoming`. Container traffic is therefore filtered in
`DOCKER-USER`, and native services in ufw. Two mechanisms, one policy.

**Second: a naive DROP breaks all container networking.** `DOCKER-USER` sits in
the `FORWARD` chain, which also carries *return* traffic for connections
containers open outbound. A bare `-i enp5s0 -j DROP` blocks that return traffic
and containers lose the internet entirely — with no error, just hangs. The
conntrack RETURN rule must come first.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Read ufw status
      ansible.builtin.command: ufw status verbose
      register: ufwst
      changed_when: false
      tags: [firewall]

    - name: ufw denies by default and allows only the native LAN services
      ansible.builtin.assert:
        that:
          - "'Status: active' in ufwst.stdout"
          - "'deny (incoming)' in ufwst.stdout"
          - ufwst.stdout is search('22.*' ~ (lan_subnet | regex_escape))
          - ufwst.stdout is search('8080.*' ~ (lan_subnet | regex_escape))
          - ufwst.stdout is search('5000.*' ~ (lan_subnet | regex_escape))
        fail_msg: "ufw is not in the expected state:\n{{ ufwst.stdout }}"
      tags: [firewall]

    - name: Read the DOCKER-USER chain
      ansible.builtin.command: iptables -S DOCKER-USER
      register: duser
      changed_when: false
      tags: [firewall]

    - name: Container traffic is filtered, with return traffic preserved
      ansible.builtin.assert:
        that:
          - duser.stdout is search('RELATED,ESTABLISHED')
          - duser.stdout is search('dport 80')
          - duser.stdout is search('-i ' ~ wan_interface ~ ' -j DROP')
        fail_msg: >-
          DOCKER-USER does not enforce the container policy:
          {{ duser.stdout }}
      tags: [firewall]

    - name: The conntrack rule precedes the drop
      ansible.builtin.assert:
        that:
          - (duser.stdout_lines | select('search', 'RELATED,ESTABLISHED')
             | list | length) > 0
          - duser.stdout_lines.index(
              duser.stdout_lines | select('search', 'RELATED,ESTABLISHED') | first
            ) < duser.stdout_lines.index(
              duser.stdout_lines | select('search', '-j DROP') | first
            )
        fail_msg: >-
          The DROP rule precedes the conntrack RETURN. Containers will lose
          outbound networking with no error message.
      tags: [firewall]
```

That last assertion looks fussy. It is checking the exact failure described
above, which presents as "containers mysteriously cannot reach the internet"
and is genuinely hard to diagnose after the fact.

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — ufw is inactive and `DOCKER-USER` holds only Docker's default RETURN.

- [ ] **Step 3: Write `roles/firewall/templates/docker-user-rules.sh.j2`**

```bash
#!/bin/bash
# Managed by Ansible.
#
# ufw cannot filter Docker published ports: Docker's nat PREROUTING and FORWARD
# rules are evaluated before ufw's INPUT chain. Container ingress is filtered
# here instead.
#
# Flush-and-rebuild rather than insert-if-missing, so the result is identical
# no matter how many times this runs and the rule ORDER is deterministic.
set -euo pipefail

LAN="{{ lan_subnet }}"
WAN="{{ wan_interface }}"

iptables -F DOCKER-USER

# Return traffic for connections containers opened outbound. This MUST be
# first: without it the DROP below blocks replies and containers silently
# lose all outbound networking.
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

# Caddy is the only container reachable from the LAN.
iptables -A DOCKER-USER -p tcp -s "$LAN" --dport 80 -j RETURN

# Everything else arriving on the LAN interface destined for a container.
iptables -A DOCKER-USER -i "$WAN" -j DROP

iptables -A DOCKER-USER -j RETURN
```

This is a Jinja template rather than a static file so the subnet and interface
come from `hosts/lab/vars.yml`. Do not write it as a static file plus a
`replace` task: after the first substitution the pattern no longer matches,
`copy` then sees a modified file and rewrites it, and the pair reports
`changed` on every run forever.

- [ ] **Step 4: Write `roles/firewall/templates/docker-user-rules.service.j2`**

```ini
[Unit]
Description=Apply DOCKER-USER firewall rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-user-rules.sh

[Install]
WantedBy=multi-user.target
```

`After=docker.service` is required because the `DOCKER-USER` chain does not
exist until Docker has started. Docker recreates the chain on daemon restart,
which is why this is a unit rather than a one-time `iptables` call.

- [ ] **Step 5: Write `roles/firewall/tasks/main.yml`**

```yaml
---
# Order is critical. Allowing 22 must happen before enabling ufw, or this
# playbook disconnects itself from a headless machine permanently.
- name: Allow SSH from the LAN
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp
    src: "{{ lan_subnet }}"

- name: Allow the native LAN services
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
    src: "{{ lan_subnet }}"
  loop:
    - "8080"   # llama-swap
    - "5000"   # beekeeper

- name: Default deny incoming
  community.general.ufw:
    direction: incoming
    policy: deny

- name: Enable ufw
  community.general.ufw:
    state: enabled

- name: Install the DOCKER-USER rule script
  ansible.builtin.template:
    src: docker-user-rules.sh.j2
    dest: /usr/local/sbin/docker-user-rules.sh
    owner: root
    group: root
    mode: "0755"
  notify: Apply docker-user rules

- name: Install the DOCKER-USER systemd unit
  ansible.builtin.template:
    src: docker-user-rules.service.j2
    dest: /etc/systemd/system/docker-user-rules.service
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Enable and start the DOCKER-USER rules unit
  ansible.builtin.systemd_service:
    name: docker-user-rules
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 6: Write `roles/firewall/handlers/main.yml`**

```yaml
---
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: Apply docker-user rules
  ansible.builtin.systemd_service:
    name: docker-user-rules
    state: restarted
```

- [ ] **Step 7: Add to the playbook, after `docker`**

```yaml
    - { role: firewall, tags: [firewall] }
```

- [ ] **Step 8: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags firewall`
Expected: `changed`, and the run completes without the connection dropping. If
the playbook hangs at "Enable ufw", the allow-22 rule did not apply — you have
roughly a session's grace to fix it from the existing connection.

- [ ] **Step 9: Confirm SSH survives on a NEW connection**

Run: `ssh -o ControlPath=none robertcowher@lab.local true; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 10: Confirm containers still have outbound networking**

Run: `ssh robertcowher@lab.local 'docker run --rm alpine sh -c "apk update >/dev/null 2>&1 && echo NET_OK"'`
Expected: `NET_OK`. A hang here means the conntrack RETURN rule is missing or
ordered after the DROP.

- [ ] **Step 11: Apply again**

Expected: `changed=0`.

- [ ] **Step 12: Run verify**

Expected: PASS. Note that "port 80 is reachable" is *not* asserted here — Caddy
does not exist until Task 11. This role asserts the rules exist; Task 11
asserts traffic actually flows.

- [ ] **Step 13: Commit**

```bash
git add roles/firewall hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(firewall): ufw for native services, DOCKER-USER chain for containers"
```

---

## Task 8: `conda` role

**Files:**
- Create: `roles/conda/tasks/main.yml`, `roles/conda/templates/conda.sh.j2`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `conda_prefix`, `conda_envs`, `ml_gid`.
- Produces: `/opt/conda/envs/beekeeper/bin/python` at 3.12, which Task 12 puts on `PATH` so upstream `setup.sh` finds the interpreter it searches for.

Conda is core infrastructure here, not a dependency workaround. It is installed
for interactive use as well as for the beekeeper service.

Two environments are created, both at 3.12: `beekeeper` for the service, and
`py312` for interactive work, which is heavily used. Both are read-only, like
the whole shared prefix. Installing into a shared env is done by cloning it —
`conda create -n mywork --clone py312` — which lands in `~/.conda/envs` and is
writable. The package cache follows the same fallback, so each user downloads
their own copies; with ~1.7TB free that is the right trade against a writable
shared prefix.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Conda environment interpreter reports the pinned version
      ansible.builtin.command: "{{ conda_prefix }}/envs/beekeeper/bin/python --version"
      register: condapy
      changed_when: false
      tags: [conda]

    - name: The beekeeper environment is Python 3.12
      ansible.builtin.assert:
        that:
          - "'3.12' in condapy.stdout"
        fail_msg: >-
          beekeeper env reports {{ condapy.stdout }}. numpy<2.0 has no wheels
          above 3.12 and setup.sh will fail at pip install.
      tags: [conda]

    - name: Conda is initialised for login shells
      ansible.builtin.stat:
        path: /etc/profile.d/conda.sh
      register: condaprofile
      tags: [conda]

    - name: Profile init exists rather than per-user bashrc edits
      ansible.builtin.assert:
        that:
          - condaprofile.stat.exists
        fail_msg: /etc/profile.d/conda.sh missing
      tags: [conda]

    - name: Inspect the conda prefix
      ansible.builtin.stat:
        path: "{{ conda_prefix }}"
      register: condaprefix
      tags: [conda]

    - name: The shared prefix is NOT group-writable
      ansible.builtin.assert:
        that:
          - condaprefix.stat.gid | int == ml_gid
          - not (condaprefix.stat.mode | int(base=8)
                 | bitwise_and(0o020))
        fail_msg: >-
          {{ conda_prefix }} is group-writable. Any ml member could mutate the
          beekeeper environment a running service depends on (spec 5.7).
      tags: [conda]

    - name: conda resolves in a login shell
      ansible.builtin.shell: bash -lc 'conda --version'
      register: condalogin
      changed_when: false
      tags: [conda]

    - name: Every declared environment exists at its pinned Python version
      ansible.builtin.command: "{{ conda_prefix }}/envs/{{ item.name }}/bin/python --version"
      register: envpy
      changed_when: false
      failed_when: item.python not in envpy.stdout
      loop: "{{ conda_envs }}"
      loop_control:
        label: "{{ item.name }}"
      tags: [conda]

    - name: robertcowher can create his own writable environment
      ansible.builtin.shell: |
        bash -lc 'conda create -y -n _verify_scratch python=3.12 --dry-run'
      become: true
      become_user: robertcowher
      register: envcreate
      changed_when: false
      tags: [conda]

    - name: Personal environment creation resolves to a writable path
      ansible.builtin.assert:
        that:
          - envcreate.rc == 0
        fail_msg: >-
          robertcowher cannot create a conda environment. The shared prefix is
          read-only by design, so conda must fall back to ~/.conda/envs; if it
          does not, envs_dirs is misconfigured.
      tags: [conda]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — `/opt/conda` does not exist.

- [ ] **Step 3: Write `roles/conda/templates/conda.sh.j2`**

```bash
# Managed by Ansible. Conda initialisation for all login shells.
#
# This lives here rather than in each user's .bashrc so there is one place to
# change it and every ml member gets the same behaviour.
__conda_setup="$('{{ conda_prefix }}/bin/conda' shell.bash hook 2>/dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
elif [ -f "{{ conda_prefix }}/etc/profile.d/conda.sh" ]; then
    . "{{ conda_prefix }}/etc/profile.d/conda.sh"
else
    export PATH="{{ conda_prefix }}/bin:$PATH"
fi
unset __conda_setup
```

- [ ] **Step 4: Write `roles/conda/tasks/main.yml`**

```yaml
---
- name: Download the Miniforge installer
  ansible.builtin.get_url:
    url: >-
      https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
    dest: /tmp/miniforge.sh
    mode: "0755"
  # conda-forge rather than Anaconda: smaller, and it avoids the Anaconda
  # commercial ToS question entirely (spec 4).

- name: Install Miniforge
  ansible.builtin.command:
    cmd: "/tmp/miniforge.sh -b -p {{ conda_prefix }}"
    creates: "{{ conda_prefix }}/bin/conda"

- name: Set ownership on the conda prefix
  ansible.builtin.file:
    path: "{{ conda_prefix }}"
    state: directory
    owner: root
    group: ml
    # 0755: readable and executable by ml, writable only by root. A writable
    # shared prefix would let any ml member mutate the environment a running
    # service depends on. Personal environments land in ~/.conda/envs, because
    # conda falls back to the first writable path in envs_dirs.
    mode: "0755"
    recurse: false

# Guarding this on the existence of .condarc does not work: the Miniforge
# installer writes that file itself for channel config, so the guard is
# already satisfied and the command never runs. Read the actual setting
# instead. Note the key is `auto_activate`; `auto_activate_base` is the old
# name and current conda does not read it.
- name: Read the current auto-activate setting
  ansible.builtin.command: "{{ conda_prefix }}/bin/conda config --system --show auto_activate"
  register: conda_autoactivate_state
  changed_when: false
  failed_when: false

- name: Disable auto-activation of the base environment
  ansible.builtin.command:
    cmd: "{{ conda_prefix }}/bin/conda config --system --set auto_activate false"
  when: "'auto_activate: False' not in conda_autoactivate_state.stdout"
  # A base env silently prepended to every shell's PATH is how the wrong
  # python ends up running a service.

- name: Create the declared environments
  ansible.builtin.command:
    cmd: >-
      {{ conda_prefix }}/bin/conda create -y
      -n {{ item.name }} python={{ item.python }}
    creates: "{{ conda_prefix }}/envs/{{ item.name }}/bin/python"
  loop: "{{ conda_envs }}"
  loop_control:
    label: "{{ item.name }}"

- name: Initialise conda for login shells
  ansible.builtin.template:
    src: conda.sh.j2
    dest: /etc/profile.d/conda.sh
    owner: root
    group: root
    mode: "0644"
```

Two traps here, both hit during execution. Do not guard this on the existence
of `.condarc` — the Miniforge installer writes that file for channel config, so
the guard is satisfied before the command ever runs. And the key is
`auto_activate`; `auto_activate_base` is the old name, and setting it silently
does nothing on current conda.

- [ ] **Step 5: Add to the playbook, after `firewall`**

```yaml
    - { role: conda, tags: [conda] }
```

- [ ] **Step 6: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags conda`
Expected: `changed`. The environment creation downloads packages and takes a
few minutes.

- [ ] **Step 7: Apply again**

Expected: `changed=0`. Both `creates:` guards should short-circuit.

- [ ] **Step 8: Run verify**

Expected: PASS, with the interpreter reporting 3.12.

- [ ] **Step 9: Commit**

```bash
git add roles/conda hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(conda): miniforge at /opt/conda, profile.d init, beekeeper env at 3.12"
```

---

## Task 9: `tools` role

**Files:**
- Create: `roles/tools/tasks/main.yml`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `tools_apt`, `tools_pipx`.
- Produces: operator tooling. Nothing later depends on it, which is the point of the split — removing anything here annoys the operator; it does not break the server.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Apt tools are installed
      ansible.builtin.command: dpkg-query -W -f='${Status}' {{ item }}
      register: tool_pkg
      changed_when: false
      # 'hold ok installed' also means installed; the nvidia role's apt-holds
      # change dpkg's first status field, so match only the parts that mean
      # the package is present.
      failed_when: "'ok installed' not in tool_pkg.stdout"
      loop: "{{ tools_apt }}"
      tags: [tools]

    - name: nvitop runs and can read the GPUs
      ansible.builtin.command: /usr/local/bin/nvitop -1
      register: nvitop_out
      changed_when: false
      tags: [tools]

    - name: nvitop exercised the driver, NVML, and the Python bindings
      ansible.builtin.assert:
        that:
          - nvitop_out.rc == 0
        fail_msg: "nvitop failed: {{ nvitop_out.stderr | default('') }}"
      tags: [tools]

    - name: Claude Code is installed for robertcowher
      ansible.builtin.command: /home/robertcowher/.local/bin/claude --version
      become: true
      become_user: robertcowher
      register: claude_v
      changed_when: false
      tags: [tools]

    - name: Claude Code reports a version
      ansible.builtin.assert:
        that:
          - claude_v.rc == 0
        fail_msg: "claude --version failed: {{ claude_v.stderr | default('') }}"
      tags: [tools]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — `nvitop` and `claude` are not installed.

- [ ] **Step 3: Write `roles/tools/tasks/main.yml`**

```yaml
---
- name: Install apt tools
  ansible.builtin.apt:
    name: "{{ tools_apt }}"
    state: present

- name: Install pipx
  ansible.builtin.apt:
    name: pipx
    state: present

- name: Install pipx-managed tools system-wide
  ansible.builtin.command:
    cmd: "pipx install {{ item }}"
    creates: "/usr/local/bin/{{ item }}"
  environment:
    # Ubuntu 26.04 enforces PEP 668, so a system-wide pip install fails
    # outright and nvitop is not packaged in the repos. This is the
    # version-agnostic system-wide pattern; 'pipx --global' is newer than
    # what 26.04 ships (spec 5.8).
    PIPX_HOME: /opt/pipx
    PIPX_BIN_DIR: /usr/local/bin
  loop: "{{ tools_pipx }}"

- name: Install Claude Code for robertcowher
  ansible.builtin.shell:
    cmd: curl -fsSL https://claude.ai/install.sh | bash
    creates: /home/robertcowher/.local/bin/claude
  become: true
  become_user: robertcowher
  # Per-user, never as root: Claude Code self-updates, and a root install
  # fights its own updater and puts credentials under the wrong home.
  # Guarded on absence rather than pinned, for the same reason.
```

Operational note worth recording where someone will find it: **nvitop must run
as root to attribute GPU processes to users.** Unprivileged, it masks processes
belonging to `beekeeper` and `llm` — which is most of what runs on this box.

- [ ] **Step 4: Add to the playbook, after `conda`**

```yaml
    - { role: tools, tags: [tools] }
```

- [ ] **Step 5: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags tools`

- [ ] **Step 6: Apply again**

Expected: `changed=0`. Both `creates:` guards short-circuit.

- [ ] **Step 7: Run verify**

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add roles/tools hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(tools): apt tooling, nvitop via pipx, Claude Code for robertcowher"
```

---

## Task 10: `llama_swap` role

**Files:**
- Create: `roles/llama_swap/tasks/main.yml`, `roles/llama_swap/templates/llama-swap.service.j2`, `roles/llama_swap/templates/config.yaml.j2`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `llama_swap_version`, `llama_swap_sha256`, `data_root`, user `llm`.
- Produces: `llama-swap.service` listening on `:8080`, already allowed through ufw by Task 7.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: llama-swap service state
      ansible.builtin.systemd_service:
        name: llama-swap
      register: lsvc
      changed_when: false
      tags: [llama_swap]

    - name: llama-swap is active and enabled
      ansible.builtin.assert:
        that:
          - lsvc.status.ActiveState == 'active'
          - lsvc.status.UnitFileState == 'enabled'
        fail_msg: "llama-swap is {{ lsvc.status.ActiveState }}"
      tags: [llama_swap]

    - name: llama-swap answers on the LAN port
      ansible.builtin.uri:
        url: http://127.0.0.1:8080/
        status_code: [200, 404]
      tags: [llama_swap]

    - name: Read the unit file
      ansible.builtin.slurp:
        src: /etc/systemd/system/llama-swap.service
      register: lsunit
      tags: [llama_swap]

    - name: Device ordering is pinned and the service runs as llm
      ansible.builtin.assert:
        that:
          - "'CUDA_DEVICE_ORDER=PCI_BUS_ID' in (lsunit.content | b64decode)"
          - "'User=llm' in (lsunit.content | b64decode)"
        fail_msg: >-
          The 3060 sorts first by PCI bus ID, so without an explicit
          CUDA_DEVICE_ORDER "GPU 0" is the smaller card (spec 3.5).
      tags: [llama_swap]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — the unit does not exist.

- [ ] **Step 3: Write `roles/llama_swap/templates/config.yaml.j2`**

```yaml
# Managed by Ansible.
#
# Model definitions are deliberately empty. llama-swap starts and serves its
# API with no models configured; adding them is an operational step that
# depends on which weights are present under {{ data_root }}/models.
#
# Each model must pin its device explicitly. This host has mismatched GPUs
# (RTX 3090 24GB and RTX 3060 12GB), so nothing can be assumed about a
# default placement, and vLLM tensor parallelism cannot split a model across
# them at all.
#
# Example shape:
#
# models:
#   "qwen2.5-7b":
#     cmd: >
#       /usr/local/bin/llama-server
#       --model {{ data_root }}/models/qwen2.5-7b-instruct-q4_k_m.gguf
#       --port ${PORT}
#       --n-gpu-layers 99
#     proxy: "http://127.0.0.1:${PORT}"
#     env:
#       - "CUDA_VISIBLE_DEVICES=0"
#     ttl: 300

healthCheckTimeout: 300

models: {}
```

- [ ] **Step 4: Write `roles/llama_swap/templates/llama-swap.service.j2`**

```ini
[Unit]
Description=llama-swap
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=llm
Group=ml
# The 3060 sorts first by PCI bus ID. Without this, "GPU 0" is the smaller
# card and every model placement decision is silently inverted (spec 3.5).
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
ExecStart=/usr/local/bin/llama-swap --config /etc/llama-swap/config.yaml --listen 0.0.0.0:8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Binding `0.0.0.0` is intentional: llama-swap is a native process, so ufw
governs its reachability and the LAN restriction is enforced there (spec 4).

- [ ] **Step 5: Write `roles/llama_swap/tasks/main.yml`**

```yaml
---
- name: Create the config directory
  ansible.builtin.file:
    path: /etc/llama-swap
    state: directory
    owner: root
    group: ml
    mode: "0755"

- name: Download the pinned llama-swap release
  ansible.builtin.get_url:
    url: >-
      https://github.com/mostlygeek/llama-swap/releases/download/v{{ llama_swap_version }}/llama-swap_{{ llama_swap_version }}_linux_amd64.tar.gz
    dest: "/tmp/llama-swap_{{ llama_swap_version }}.tar.gz"
    checksum: "sha256:{{ llama_swap_sha256 }}"
    mode: "0644"

- name: Unpack llama-swap
  ansible.builtin.unarchive:
    src: "/tmp/llama-swap_{{ llama_swap_version }}.tar.gz"
    dest: /usr/local/bin
    remote_src: true
    include: [llama-swap]
    owner: root
    group: root
    mode: "0755"
    creates: /usr/local/bin/llama-swap

- name: Write the llama-swap config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/llama-swap/config.yaml
    owner: root
    group: ml
    mode: "0644"
  notify: Restart llama-swap

- name: Install the systemd unit
  ansible.builtin.template:
    src: llama-swap.service.j2
    dest: /etc/systemd/system/llama-swap.service
    owner: root
    group: root
    mode: "0644"
  notify: Restart llama-swap

- name: Enable and start llama-swap
  ansible.builtin.systemd_service:
    name: llama-swap
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 6: Write `roles/llama_swap/handlers/main.yml`**

```yaml
---
- name: Restart llama-swap
  ansible.builtin.systemd_service:
    name: llama-swap
    state: restarted
    daemon_reload: true
```

- [ ] **Step 7: Add to the playbook, after `tools`**

```yaml
    - { role: llama_swap, tags: [llama_swap] }
```

- [ ] **Step 8: Apply, then apply again**

Expected: `changed` then `changed=0`.

- [ ] **Step 9: Run verify**

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add roles/llama_swap hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(llama_swap): pinned v253 with checksum, unit as llm, PCI bus ordering"
```

---

## Task 11: `webstack` role

**Files:**
- Create: `roles/webstack/tasks/main.yml`, `roles/webstack/templates/docker-compose.yml.j2`, `roles/webstack/templates/Caddyfile.j2`, `roles/webstack/templates/docker-compose@.service.j2`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `data_root`, `user_uids`, `lan_subnet`, Docker from Task 6, `DOCKER-USER` rules from Task 7.
- Produces: Caddy on `:80` routing to Open WebUI and File Browser. This is the task that proves Task 7's firewall rules actually work.

**Read this before writing the Caddyfile.** Caddy runs *in a container*, so
`127.0.0.1` inside it is the Caddy container itself, not the host. Proxying to
`127.0.0.1:3000` would fail with connection refused. Caddy must address the
other services by their **compose service names** over the shared compose
network. The `127.0.0.1:3000` and `127.0.0.1:8081` in the spec's bind table
describe *host-side publication* — kept for debuggability and so the `ss` check
can confirm nothing containerized is on a LAN address — not the path Caddy
takes.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: Compose unit state
      ansible.builtin.systemd_service:
        name: docker-compose@webstack
      register: wsvc
      changed_when: false
      tags: [webstack]

    - name: The webstack compose project is active and enabled
      ansible.builtin.assert:
        that:
          - wsvc.status.ActiveState == 'active'
          - wsvc.status.UnitFileState == 'enabled'
        fail_msg: "docker-compose@webstack is {{ wsvc.status.ActiveState }}"
      tags: [webstack]

    - name: Caddy serves Open WebUI at the root
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}/"
        status_code: [200, 302, 401]
        follow_redirects: none
      tags: [webstack]

    - name: Caddy serves File Browser under /files
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}/files/"
        status_code: [200, 302, 401]
        follow_redirects: none
      tags: [webstack]

    - name: /beekeeper redirects rather than proxying
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}/beekeeper"
        status_code: [301, 302]
        follow_redirects: none
      register: bkredir
      tags: [webstack]

    - name: The beekeeper redirect points at port 5000
      ansible.builtin.assert:
        that:
          - "':5000' in bkredir.location"
        fail_msg: >-
          /beekeeper must redirect to :5000, not proxy. Beekeeper has no
          subpath support and its escaped paths would silently match Open
          WebUI's routes (spec 3.2).
      tags: [webstack]

    - name: Enumerate listening TCP sockets
      ansible.builtin.command: ss -ltnH
      register: sockets
      changed_when: false
      tags: [webstack]

    - name: No containerized service listens on a LAN address
      ansible.builtin.assert:
        that:
          - sockets.stdout is not search('0.0.0.0:3000')
          - sockets.stdout is not search('0.0.0.0:8081')
          - sockets.stdout is not search('0.0.0.0:9100')
          - sockets.stdout is not search('0.0.0.0:9400')
          - sockets.stdout is not search(ansible_host | regex_escape ~ ':3000')
        fail_msg: >-
          A containerized service is bound to a LAN address. ufw cannot filter
          Docker published ports, so this is reachable from the LAN despite
          default-deny (spec 3.1).
      tags: [webstack]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — the compose unit does not exist.

- [ ] **Step 3: Write `roles/webstack/templates/Caddyfile.j2`**

```
# Managed by Ansible.
:80 {
	# Upstreams are addressed by compose SERVICE NAME, not 127.0.0.1. Caddy
	# runs in a container, so loopback is the Caddy container itself. The
	# 127.0.0.1 publications in the compose file exist for host-side
	# debugging and to keep these services off any LAN address.

	handle_path /files/* {
		reverse_proxy filebrowser:80
	}

	# Beekeeper is NOT proxied. It has no ProxyFix, APPLICATION_ROOT, or
	# SCRIPT_NAME handling, and its templates hardcode absolute paths like
	# /admin and /api/v1/docs. Proxied under a subpath it would break, and
	# break silently INTO Open WebUI, whose routes match the escaped paths.
	redir /beekeeper /beekeeper/
	handle /beekeeper/* {
		redir http://lab.local:5000/ 302
	}

	handle {
		reverse_proxy open-webui:8080
	}
}
```

- [ ] **Step 4: Write `roles/webstack/templates/docker-compose.yml.j2`**

```yaml
# Managed by Ansible.
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    # The ONLY container published to the LAN. Reachability is enforced by the
    # DOCKER-USER rules from the firewall role, because ufw cannot filter
    # Docker published ports.
    ports:
      - "80:80"
    volumes:
      - /etc/docker/compose/webstack/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - open-webui
      - filebrowser

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:8080"
    environment:
      - OLLAMA_BASE_URL=
      - OPENAI_API_BASE_URL=http://{{ ansible_default_ipv4.address }}:8080/v1
    volumes:
      - {{ data_root }}/open-webui:/app/backend/data

  filebrowser:
    image: filebrowser/filebrowser:s6
    restart: unless-stopped
    ports:
      - "127.0.0.1:8081:80"
    # Runs as the 'files' user so files on disk carry correct ownership.
    user: "{{ user_uids['files'] }}:{{ ml_gid }}"
    environment:
      # Subpath hosting: File Browser, unlike beekeeper, supports it.
      - FB_BASEURL=/files
    volumes:
      - {{ data_root }}:/srv
      - {{ data_root }}/filebrowser/database.db:/database.db

  node-exporter:
    image: prom/node-exporter:latest
    restart: unless-stopped
    # Host network so the metrics describe the host rather than a namespace.
    # The listen address keeps it off every LAN address regardless.
    network_mode: host
    pid: host
    command:
      - "--path.rootfs=/host"
      - "--web.listen-address=127.0.0.1:9100"
    volumes:
      - /:/host:ro,rslave

  dcgm-exporter:
    image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04
    restart: unless-stopped
    runtime: nvidia
    ports:
      - "127.0.0.1:9400:9400"
    cap_add:
      - SYS_ADMIN

volumes:
  caddy_data:
  caddy_config:
```

- [ ] **Step 5: Write `roles/webstack/templates/docker-compose@.service.j2`**

```ini
[Unit]
Description=Docker Compose project %i
Requires=docker.service
After=docker.service docker-user-rules.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/etc/docker/compose/%i
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

`After=docker-user-rules.service` matters: starting containers before the
firewall rules are in place leaves a window where published ports are open to
the LAN.

- [ ] **Step 6: Write `roles/webstack/tasks/main.yml`**

```yaml
---
- name: Create the compose project directory
  ansible.builtin.file:
    path: /etc/docker/compose/webstack
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Create service state directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ user_uids['files'] }}"
    group: ml
    mode: "2775"
  loop:
    - "{{ data_root }}/open-webui"
    - "{{ data_root }}/filebrowser"

- name: Create the File Browser database file if absent
  ansible.builtin.file:
    path: "{{ data_root }}/filebrowser/database.db"
    state: touch
    owner: "{{ user_uids['files'] }}"
    group: ml
    mode: "0664"
    modification_time: preserve
    access_time: preserve
  # Without this, Docker creates a DIRECTORY at the bind-mount path and File
  # Browser fails to open its database.

- name: Write the Caddyfile
  ansible.builtin.template:
    src: Caddyfile.j2
    dest: /etc/docker/compose/webstack/Caddyfile
    owner: root
    group: root
    mode: "0644"
  notify: Restart webstack

- name: Write the compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: /etc/docker/compose/webstack/docker-compose.yml
    owner: root
    group: root
    mode: "0644"
  notify: Restart webstack

- name: Install the templated compose unit
  ansible.builtin.template:
    src: docker-compose@.service.j2
    dest: /etc/systemd/system/docker-compose@.service
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Enable and start the webstack project
  ansible.builtin.systemd_service:
    name: docker-compose@webstack
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 7: Write `roles/webstack/handlers/main.yml`**

```yaml
---
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: Restart webstack
  ansible.builtin.systemd_service:
    name: docker-compose@webstack
    state: restarted
```

- [ ] **Step 8: Add to the playbook, after `llama_swap`**

```yaml
    - { role: webstack, tags: [webstack] }
```

- [ ] **Step 9: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags webstack`
Expected: `changed`. First run pulls several images and takes a few minutes.

- [ ] **Step 10: Confirm the firewall boundary from ANOTHER machine**

From your workstation, not from lab:

```bash
curl -sS -o /dev/null -w "caddy:%{http_code}\n" http://192.168.1.30/
curl -sS -m 5 -o /dev/null -w "openwebui-direct:%{http_code}\n" http://192.168.1.30:3000/ || echo "openwebui-direct: refused (correct)"
```
Expected: Caddy answers; port 3000 is refused or times out. **If port 3000
answers, Task 7's DOCKER-USER rules are not working** — that is the exact
failure spec §3.1 exists to prevent, and it must be fixed before continuing.

- [ ] **Step 11: Apply again**

Expected: `changed=0`.

- [ ] **Step 12: Run verify**

Expected: PASS.

- [ ] **Step 13: Commit**

```bash
git add roles/webstack hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(webstack): caddy-fronted compose project, loopback-only backends"
```

---

## Task 12: `beekeeper` role

**Files:**
- Create: `roles/beekeeper/tasks/main.yml`, `roles/beekeeper/templates/beekeeper-sudoers.j2`
- Modify: `hosts/lab/main.yml`, `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `beekeeper_branch`, `beekeeper_home`, `conda_prefix`, user `beekeeper`.
- Produces: `beekeeper.service` on `:5000`, already allowed through ufw by Task 7 and redirected to by Task 11.

Upstream `setup.sh` owns the systemd unit: it templates the unit with
`User=$CURRENT_USER` and calls `sudo` to install it. Ansible runs `setup.sh`
rather than writing the unit, so the service user is whoever Ansible runs it as,
and that user needs targeted sudo rights.

The repo is **public**, so it is cloned over HTTPS and no deploy key is
required. `beekeeper_branch` is set to `develop` because `deploy.sh` resets the
checkout to `origin/develop`; if Ansible cloned `main` the two would fight.

- [ ] **Step 1: Write the failing assertions**

Append to `hosts/lab/verify.yml`:

```yaml
    - name: beekeeper service state
      ansible.builtin.systemd_service:
        name: beekeeper
      register: bksvc
      changed_when: false
      tags: [beekeeper]

    - name: beekeeper is active and enabled
      ansible.builtin.assert:
        that:
          - bksvc.status.ActiveState == 'active'
          - bksvc.status.UnitFileState == 'enabled'
        fail_msg: "beekeeper is {{ bksvc.status.ActiveState }}"
      tags: [beekeeper]

    - name: The API answers on the port its consumers expect
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}:5000/api/v1/busy"
        return_content: true
      register: busy
      tags: [beekeeper]

    - name: The busy endpoint returns valid JSON
      ansible.builtin.assert:
        that:
          - busy.json is defined
        fail_msg: >-
          /api/v1/busy did not return JSON. deploy.sh polls this endpoint
          before restarting, and the MCP config and generated agent SDKs both
          bake in this address (spec 3.2).
      tags: [beekeeper]

    - name: The service venv uses the conda 3.12 interpreter
      ansible.builtin.command: "{{ beekeeper_home }}/venv/bin/python --version"
      register: bkpy
      changed_when: false
      tags: [beekeeper]

    - name: beekeeper is not running on Python 3.13 or newer
      ansible.builtin.assert:
        that:
          - "'3.12' in bkpy.stdout"
        fail_msg: >-
          venv reports {{ bkpy.stdout }}. numpy<2.0 has no wheels above 3.12.
      tags: [beekeeper]

    - name: The sudoers drop-in parses
      ansible.builtin.command: /usr/sbin/visudo -cf /etc/sudoers.d/beekeeper
      register: bksudo
      changed_when: false
      tags: [beekeeper]
```

- [ ] **Step 2: Run verify to confirm it fails**

Expected: FAIL — the unit does not exist.

- [ ] **Step 3: Write `roles/beekeeper/templates/beekeeper-sudoers.j2`**

```
# Managed by Ansible. Installed with visudo validation.
#
# Upstream setup.sh installs its own systemd unit via sudo (spec 3.4), so the
# beekeeper user needs to manage exactly that unit and nothing else.
#
# NOTE: permitting a write to the unit file is effectively root-equivalent —
# whoever can write a unit can run arbitrary code as root. That follows
# directly from the decision to let setup.sh own the unit. If that tradeoff
# stops being acceptable, the alternative is for Ansible to template the unit
# itself and grant only the systemctl verbs below.
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl start beekeeper
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl stop beekeeper
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl restart beekeeper
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl status beekeeper
beekeeper ALL=(root) NOPASSWD: /usr/bin/systemctl enable beekeeper
beekeeper ALL=(root) NOPASSWD: /usr/bin/tee /etc/systemd/system/beekeeper.service
```

- [ ] **Step 4: Write `roles/beekeeper/tasks/main.yml`**

```yaml
---
- name: Install the sudoers drop-in
  ansible.builtin.template:
    src: beekeeper-sudoers.j2
    dest: /etc/sudoers.d/beekeeper
    owner: root
    group: root
    mode: "0440"
    # Not optional. An unvalidated sudoers file is one of the few ways a
    # playbook can lock the operator out of the host entirely: a parse error
    # in /etc/sudoers.d breaks sudo for every user, robertcowher included.
    validate: /usr/sbin/visudo -cf %s

- name: Clone the beekeeper repository
  ansible.builtin.git:
    repo: https://github.com/bobcowher/beekeeper.git
    dest: "{{ beekeeper_home }}"
    version: "{{ beekeeper_branch }}"
    # The repo is public, so no deploy key is needed. deploy.sh only ever
    # fetches; it never pushes.
    update: true
  become: true
  become_user: beekeeper
  register: bk_checkout

- name: Check whether the venv already exists
  ansible.builtin.stat:
    path: "{{ beekeeper_home }}/venv/bin/python"
  register: bk_venv

- name: Run the upstream setup script
  ansible.builtin.command:
    cmd: bash setup.sh -y
    chdir: "{{ beekeeper_home }}"
  become: true
  become_user: beekeeper
  environment:
    # setup.sh searches for python3.12, 3.11, 3.10, then falls back to
    # python3. Only 3.14 exists natively, and numpy<2.0 has no wheels for it,
    # so the conda env is placed ahead on PATH to supply python3.12 (spec 3.3).
    PATH: "{{ conda_prefix }}/envs/beekeeper/bin:/usr/local/bin:/usr/bin:/bin"
  # Runs only when the checkout moved or the venv is missing, so a no-op play
  # does not rebuild the environment on every run.
  when: bk_checkout.changed or not bk_venv.stat.exists

- name: Ensure the service is enabled and running
  ansible.builtin.systemd_service:
    name: beekeeper
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 5: Add to the playbook, after `webstack`**

```yaml
    - { role: beekeeper, tags: [beekeeper] }
```

- [ ] **Step 6: Apply**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags beekeeper`
Expected: `changed`. `setup.sh` builds a venv and pip-installs; this takes
several minutes.

- [ ] **Step 7: Confirm sudo still works for robertcowher**

Run: `ssh robertcowher@lab.local 'sudo -n true 2>&1 | head -1; sudo -l | head -5'`
Expected: sudo still functions. Do this immediately after the first apply — a
broken `/etc/sudoers.d/beekeeper` breaks sudo for everyone, and `validate:`
should have prevented it, but confirm rather than assume.

- [ ] **Step 8: Apply again**

Expected: `changed=0`, and `setup.sh` is **skipped**. If it re-runs, the guard
is wrong and every play rebuilds the venv.

- [ ] **Step 9: Run verify**

Expected: PASS, with `/api/v1/busy` returning JSON.

- [ ] **Step 10: Confirm the redirect chain end to end**

From your workstation:

```bash
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://192.168.1.30/beekeeper
```
Expected: a 302 to `http://lab.local:5000/`.

- [ ] **Step 11: Commit**

```bash
git add roles/beekeeper hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(beekeeper): validated sudoers, HTTPS clone, guarded upstream setup.sh"
```

---

## Task 13: Full-run validation

**Files:**
- Modify: none expected.

- [ ] **Step 1: Run the entire playbook from scratch on the configured host**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml`
Expected: `changed=0` across every role. Anything that reports `changed` here
is a role that does work on every run — find it and fix it.

- [ ] **Step 2: Run the entire verify playbook**

Run: `ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml`
Expected: all assertions pass.

- [ ] **Step 3: Lint everything**

Run: `ansible-lint hosts/ roles/`
Expected: clean, or only warnings you have consciously accepted.

- [ ] **Step 4: Reboot and re-verify**

This is the test that matters most and the one most easily skipped. Nothing so
far proves the configuration survives a restart — in particular the
`DOCKER-USER` rules, which live in a chain Docker recreates on daemon start.

```bash
ssh robertcowher@lab.local 'sudo systemctl reboot'
# wait for it to come back
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```
Expected: all assertions still pass. Confirm from your workstation that port
3000 is still refused.

- [ ] **Step 5: Commit any fixes and tag the working state**

```bash
git tag -a lab-v1 -m "lab server fully configured and verified after reboot"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task:

| Spec | Task |
|---|---|
| 2 — verified facts | 1 (release assertion) |
| 3.1 — ufw vs Docker | 7, verified in 11 |
| 3.2 — no subpath support | 11 (redirect, not proxy) |
| 3.3 — Python 3.14 | 8, consumed in 12 |
| 3.4 — setup.sh owns the unit | 12 (validated sudoers) |
| 3.5 — mismatched GPUs | 10 (`CUDA_DEVICE_ORDER`) |
| 3.6 — unattended-upgrades | 2 (origins), 5 (holds) |
| 3.7 — mDNS single name | 11 (path routing) |
| 4 — decisions | 4, 5, 8, 9, 10, 12 |
| 5.1–5.11 — roles | 2–12 |
| 6 — bind table | 11 (`ss` assertion) |
| 7 — repo layout | 1 |
| 8 — verification | every task, plus 13 |
| 10 — deferred | Global Constraints (explicitly not implemented) |

**Placeholder scan.** One deliberate near-miss: `roles/llama_swap/templates/config.yaml.j2`
ships `models: {}`. That is a complete, valid, working config — llama-swap
starts and serves with no models — not a TBD. Which weights to register depends
on what gets downloaded to `/data/models` and is an operational step, not an
implementation one. The example shape is in the file as a comment.

**Type consistency.** Variable names are consistent across tasks:
`user_uids` is a dict keyed by name (Tasks 1, 3, 11); `lab_users` is a list of
dicts with `name`/`shell`/`groups` (Tasks 1, 3, 6); `ml_gid`, `lan_subnet`,
`wan_interface`, `data_root`, `conda_prefix` are scalars used identically
everywhere. Verify tags match role names one-for-one.

**Fixed during review:** Task 7 originally presented a `copy` + `replace` pair
before explaining that it reports `changed` forever. An executor working
task-by-task could have implemented the wrong block, so the task now gives only
the template version, with the reason stated as a caution rather than as
demonstrated wrong code.

---

## Deliberately Not In This Plan

From spec §10. Do not add these without being asked:

- **Tailscale** — excluded from this iteration.
- **Backups** — `restic` is installed as a package and left unconfigured. No repos, timers, retention, or credentials. This remains the largest outstanding risk on the host: `/data` sits on root, on a single NVMe, with no redundancy.
- **`disk-check.timer`** — script undefined.
- **Moving beekeeper's state out of the checkout** — belongs in the beekeeper repo.
- **Removing beekeeper's `numpy<2.0` pin** — belongs in the beekeeper repo.
- **Beekeeper subpath support** — belongs in the beekeeper repo; prerequisite for real hostnames and TLS.
