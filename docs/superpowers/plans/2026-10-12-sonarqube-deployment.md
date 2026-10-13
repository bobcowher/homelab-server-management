# SonarQube Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Robert's SonarQube fork from source on lab and serve it from a
release symlink, with this repository as the sole recovery path.

**Architecture:** A new `roles/sonarqube` installs JDK 21, PostgreSQL 18, a
service account, two environment files and a systemd unit, and bootstrap-clones
the fork once. A `sonarqube-deploy` script owns the build/swap/rollback cycle:
it builds the zip, unpacks it to `releases/<version>-<sha>`, flips
`/opt/sonarqube/current`, restarts the unit, and rolls the symlink back if the
new release does not reach `UP`. All configuration reaches the JVM through the
environment, so nothing is written inside a release directory.

**Tech Stack:** Ansible, systemd, bash, PostgreSQL 18, OpenJDK 21, Gradle
(from the fork's wrapper), ufw, Caddy.

**Spec:** `docs/superpowers/specs/2026-10-12-sonarqube-deployment-design.md`

## Scope

Deployment only. The fork at `github.com/bobcowher/sonarqube` is Robert's, and
the only thing asked of it is the artifact its own README already documents:
`./gradlew :sonar-application:zip`. **No task in this plan creates, edits or
commits a file in that repository** -- not because of a prohibition, but
because every file added there is a conflict surface at the next
`git rebase upstream/master`.

## Global Constraints

Copied verbatim from the spec. Every task's requirements include these.

- **No version string for SonarQube appears anywhere in this repository.**
  Version comes from the zip's own directory name, the SHA from git, the jar
  from a glob.
- **Never install a plugin through the SonarQube web UI on this host.** There
  is no `sonar.path.extensions`; a Marketplace plugin lives inside the release
  directory and is destroyed by the next deploy. Anything needed gets bundled
  in the fork, where a git SHA describes it.
- **The repository is public.** The generated database password must never be
  rendered into a file under version control. Generate on the host, `creates:`
  guarded, read back with `slurp` -- the pattern in
  `roles/webstack/tasks/main.yml` for the SearXNG key.
- **`/opt/sonarqube/src` is cloned with `update: false`.** Ansible bootstraps
  it once and never touches it again, so a playbook run cannot revert what a
  deploy checked out. Same contract as `/opt/bobgpt/src`.
- **Configuration reaches SonarQube only through the environment.**
  `sonar.jdbc.url` is `SONAR_JDBC_URL`; the mapping is uppercase with `.` and
  `-` both to `_` (`SettingFormatter.java:32`). Nothing is templated into a
  release directory.
- **SonarQube gets no signal in the power role.** It must never veto the
  overnight shutdown.
- **PostgreSQL floor is 14** (the fork's shipped
  `conf/sonar.properties:41` says "PostgreSQL 14 or greater"). Ubuntu 26.04
  offers 18.6 only.
- **Elasticsearch bootstrap limits:** `LimitNOFILE=131072`,
  `LimitNPROC=8192`, `vm.max_map_count >= 524288`. Low values make the
  service refuse to start.
- Idle thresholds this service must stay under: `power_idle_cpu_max: "5.0"`,
  `power_idle_load_max: "0.50"`, measured over `power_idle_window_minutes: 60`.

## How "TDD" works in this repository

There is no unit-test framework for Ansible here, and the repository has
settled on two real testing mechanisms. Use both; do not invent a third.

1. **`hosts/lab/verify.yml`** is the acceptance test. It reads the host back
   and asserts, independently of Ansible's own change reporting. The TDD cycle
   is: add the assertion, run `ansible-playbook -i inventory/hosts.yml
   hosts/lab/verify.yml --tags sonarqube` and **watch it fail**, implement the
   role, apply, watch it pass.
2. **`scripts/test_sonarqube_deploy.sh`** is a bash unit-test harness for the
   deploy script's decision logic, modelled on the existing
   `scripts/test_idle_checks.sh`. The risky parts of a deploy -- ambiguous
   artifacts, a release that will not start, pruning -- cannot be exercised by
   running real 20-minute builds, so they are tested against stubs. This is
   where genuine red-green-refactor happens.

A false green is the failure mode to fear here. `verify.yml` once passed a
"cannot write" assertion because the probe command itself errored. **Every
assertion added by this plan must be seen to fail for the right reason before
it is made to pass.**

## File Structure

**Created:**

- `roles/sonarqube/tasks/main.yml` -- the whole role. One file, matching
  `roles/bobgpt` and `roles/webstack`; this repository does not split role
  tasks into includes.
- `roles/sonarqube/handlers/main.yml` -- restart handler.
- `roles/sonarqube/templates/sonarqube.service.j2` -- the unit.
- `roles/sonarqube/templates/sonarqube.env.j2` -- `SONAR_*` keys, holds the
  password, `0640 root:sonarqube`.
- `roles/sonarqube/templates/deploy.env.j2` -- deploy policy, `0644`, no
  secrets.
- `roles/sonarqube/files/sonarqube-deploy` -- build, swap, verify, roll back,
  prune. A plain file, not a template: every input comes from `deploy.env`, so
  it has nothing to interpolate and can be tested standalone.
- `roles/sonarqube/files/sonarqube-run` -- globs the versioned jar and execs
  java. Exists only because `ExecStart` cannot glob.
- `roles/sonarqube/files/99-sonarqube.conf` -- the `vm.max_map_count` sysctl
  drop-in.
- `scripts/test_sonarqube_deploy.sh` -- unit tests for the deploy script.
- `scripts/smoke_sonarqube.sh` -- end-to-end branch-analysis check.

**Modified:**

- `hosts/lab/vars.yml` -- the `sonarqube_*` block.
- `hosts/lab/main.yml` -- the role, before `power`.
- `hosts/lab/verify.yml` -- the assertion block.
- `requirements.yml` -- add `community.postgresql`.
- `roles/firewall/tasks/main.yml` -- port 9000 from the LAN.
- `roles/webstack/templates/Caddyfile.j2` -- the `/sonar` redirect.
- `docs/RUNBOOK.md` -- operations and recovery.

## Review Focus

Five failure modes the spec implies that a happy-path deploy would never
exercise. Each has a named test in the task that owns the code.

1. **Two zips in `build/distributions`.** A stale artifact alongside a fresh
   one must abort the deploy, not be silently chosen by date. Picking "the
   newest" would deploy the wrong code and look successful. *(Task 4)*
2. **A release that builds but will not start.** The symlink must return to the
   previous release and that release must be serving again before the script
   exits non-zero. A deploy that leaves the box down is worse than one that
   refuses. *(Task 4)*
3. **The very first deploy, failing to start, with no previous release.** There
   is nothing to roll back to. It must fail loudly and must not leave
   `current` dangling at a release that cannot run. *(Task 4)*
4. **Pruning must never delete the live release**, however old its mtime. A
   redeploy of an earlier SHA makes the live directory not the newest, and
   deleting it would delete the running server's own jars. *(Task 4)*
5. **Idle SonarQube holding the box awake.** Three idle JVMs could push `sar`
   CPU over 5.0% or load over 0.50 and silently cancel every overnight
   shutdown -- invisible until someone notices the box never powers off.
   *(Task 8)*

---

### Task 1: JDK 21, the sysctl floor, and the role in the play

**Files:**
- Create: `roles/sonarqube/tasks/main.yml`
- Create: `roles/sonarqube/files/99-sonarqube.conf`
- Modify: `hosts/lab/vars.yml`
- Modify: `hosts/lab/main.yml`
- Modify: `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `data_root`, `conda_prefix` from `hosts/lab/vars.yml`.
- Produces: the `sonarqube_*` variable block every later task reads, and a
  `roles/sonarqube` that later tasks append to. Names later tasks rely on:
  `sonarqube_user`, `sonarqube_root`, `sonarqube_repo`, `sonarqube_branch`,
  `sonarqube_port`, `sonarqube_data_dir`, `sonarqube_log_dir`,
  `sonarqube_db_name`, `sonarqube_db_user`, `sonarqube_keep_releases`,
  `sonarqube_start_timeout`.

- [ ] **Step 1: Add the variable block to `hosts/lab/vars.yml`**

Append at the end of the file:

```yaml
# --- sonarqube ---------------------------------------------------------------
#
# Robert's fork of SonarQube Community Build, built from source ON this host
# and served from a release symlink. The fork is github.com/bobcowher/sonarqube
# and adds one feature commit: long-lived branch analysis, bundled as a plugin
# rather than installed as one.
#
# Deliberately NO version anywhere below. The running version comes from the
# zip the build produces and is read back by verify.yml from
# /api/server/version. See
# docs/superpowers/specs/2026-10-12-sonarqube-deployment-design.md.
sonarqube_user: sonarqube
sonarqube_root: /opt/sonarqube
sonarqube_repo: https://github.com/bobcowher/sonarqube.git

# Bootstrap-and-deploy policy, not a pin: Ansible clones this once and
# sonarqube-deploy resets to it. Changing it here changes what the next deploy
# builds.
sonarqube_branch: master

# Binds all interfaces because the scanner and the browser both come from the
# LAN. ufw is what keeps it private -- allowed from lan_subnet only. Unlike
# bobgpt and llama-swap there is NO docker_bridge_subnet rule: nothing in a
# container talks to SonarQube, so that rule would be surface for no gain.
sonarqube_port: 9000

# All mutable state lives outside the release tree, so flipping the symlink
# touches none of it. sonar.path.data/.temp/.logs are relocatable
# (ProcessProperties.java:69-73) and absolute paths are honoured.
sonarqube_data_dir: "{{ data_root }}/sonarqube"
sonarqube_log_dir: /var/log/sonarqube

sonarqube_db_name: sonarqube
sonarqube_db_user: sonarqube

# How many unpacked releases to keep. Rollback needs at least two; three gives
# one spare. Each is roughly 1GB unpacked.
sonarqube_keep_releases: 3

# Seconds to wait for /api/system/status to report UP after a restart before
# treating the deploy as failed and rolling back. Elasticsearch plus two JVMs
# takes 60-90s cold on this box, so this is generous on purpose: a rollback
# triggered by impatience would be worse than a slow deploy.
sonarqube_start_timeout: 300
```

- [ ] **Step 2: Add the failing assertions to `hosts/lab/verify.yml`**

Insert before the `# --- bobgpt ---` comment block (currently near line 644),
so the sonarqube block sits with the other service blocks:

```yaml
    # --- sonarqube ------------------------------------------------------------
    #
    # Robert's SonarQube fork, built from source on this host. These assertions
    # cover the host contract: the toolchain, the limits Elasticsearch checks
    # at startup, and -- further down, added by later tasks -- that the version
    # actually serving matches the release the symlink points at.
    - name: The SonarQube build and run toolchain is installed
      ansible.builtin.command: dpkg-query -W -f='${Status}' {{ item }}
      register: sonarqube_pkg
      changed_when: false
      failed_when: "'ok installed' not in sonarqube_pkg.stdout"
      loop:
        - openjdk-21-jdk
        - unzip
      tags: [sonarqube]

    - name: Read the Java version
      ansible.builtin.command: java -version
      register: sonarqube_java
      changed_when: false
      tags: [sonarqube]

    # The fork's gradle.properties names jdk-21.0.12.1+1, and the build fails
    # on anything older than 21. Assert the major version rather than the full
    # string so a security patch does not break verification.
    - name: Java is version 21
      ansible.builtin.assert:
        that:
          - "'version \"21.' in (sonarqube_java.stderr + sonarqube_java.stdout)"
        fail_msg: >-
          Expected Java 21 for the SonarQube build, got:
          {{ (sonarqube_java.stderr + sonarqube_java.stdout) | trim }}
      tags: [sonarqube]

    - name: Read vm.max_map_count
      ansible.builtin.command: sysctl -n vm.max_map_count
      register: sonarqube_mmap
      changed_when: false
      tags: [sonarqube]

    # Bundled Elasticsearch runs a bootstrap check against this and refuses to
    # start below 524288. Lab reports far more than that by default, but this
    # asserts the sysctl drop-in rather than trusting a default that could
    # change under a kernel or sysctl-package update.
    - name: vm.max_map_count is above the Elasticsearch floor
      ansible.builtin.assert:
        that:
          - sonarqube_mmap.stdout | int >= 524288
        fail_msg: >-
          vm.max_map_count is {{ sonarqube_mmap.stdout }}, below the 524288
          bundled Elasticsearch requires. It will refuse to start.
      tags: [sonarqube]
```

- [ ] **Step 3: Run the assertions and watch them fail**

```bash
cd /home/robertcowher/ansibleprojects/lab_server
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags sonarqube
```

Expected: FAIL on "The SonarQube build and run toolchain is installed", because
`openjdk-21-jdk` is not installed on lab. Confirm the failure names
`openjdk-21-jdk` and is **not** an undefined-variable error -- an undefined
variable would mean Step 1 did not take effect and the test is failing for the
wrong reason.

- [ ] **Step 4: Write the sysctl drop-in**

`roles/sonarqube/files/99-sonarqube.conf`:

```
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
#
# Bundled Elasticsearch runs a bootstrap check against vm.max_map_count and
# refuses to start below 524288. Lab already reports 1048576 from the default
# configuration, so this file changes nothing today -- it exists so the value
# is OWNED rather than inherited, and so a future kernel or sysctl package
# cannot lower it silently and leave SonarQube unable to start.
vm.max_map_count = 1048576
```

- [ ] **Step 5: Create the role with the toolchain tasks**

`roles/sonarqube/tasks/main.yml`:

```yaml
---
# Provisions lab to BUILD and SERVE Robert's SonarQube fork from source.
#
# The fork is github.com/bobcowher/sonarqube: SonarQube Community Build plus
# one commit adding long-lived branch analysis. This role installs the
# toolchain, the database, a service account, two environment files, a unit and
# a deploy script -- and never names a SonarQube version. The version comes
# from whatever the build produces.
#
# See docs/superpowers/specs/2026-10-12-sonarqube-deployment-design.md.

# openjdk-21-jdk, not -jre: the Gradle build needs a compiler, and this host
# is the build machine as well as the server. Ubuntu 26.04 carries
# 21.0.12.1+1, which is the jre_release_name the fork's gradle.properties
# names -- the build and the runtime agree by accident of good timing, not by
# anything this role enforces.
#
# unzip is needed by sonarqube-deploy to unpack the distribution. It is also
# in tools_apt, but this role must stand on its own: a host provisioned with
# --tags sonarqube alone has to work.
- name: Install the SonarQube build and run toolchain
  ansible.builtin.apt:
    name:
      - openjdk-21-jdk
      - unzip
    state: present

- name: Install the sysctl drop-in for Elasticsearch
  ansible.builtin.copy:
    src: 99-sonarqube.conf
    dest: /etc/sysctl.d/99-sonarqube.conf
    owner: root
    group: root
    mode: "0644"
  notify: Reload sysctl
```

- [ ] **Step 6: Create the handler**

`roles/sonarqube/handlers/main.yml`:

```yaml
---
- name: Reload sysctl
  ansible.builtin.command: sysctl --system
  changed_when: true
```

- [ ] **Step 7: Add the role to the play**

In `hosts/lab/main.yml`, insert after the `bobgpt` role and before the comment
block above `power`:

```yaml
    - { role: sonarqube, tags: [sonarqube] }
```

The ordering comment above `power` lists the services whose state the idle
check reads. SonarQube is deliberately **not** one of them -- it has no veto
signal -- so the comment does not need changing, but `sonarqube` must still sit
before `power` so the whole box is in its final state when the idle check is
installed and dry-run.

- [ ] **Step 8: Apply and watch the assertions pass**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube
```

Expected: the apply installs the JDK (this takes a couple of minutes), then the
imported `verify.yml` reports the sonarqube assertions passing. Note that
`--tags sonarqube` also runs the `always`-tagged verify tasks; that is normal.

- [ ] **Step 9: Commit**

```bash
git add roles/sonarqube hosts/lab/vars.yml hosts/lab/main.yml hosts/lab/verify.yml
git commit -m "feat(sonarqube): JDK 21 and the Elasticsearch sysctl floor"
```

---

### Task 2: PostgreSQL 18, the database, and a generated password

**Files:**
- Modify: `requirements.yml`
- Modify: `roles/sonarqube/tasks/main.yml`
- Modify: `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `sonarqube_db_name`, `sonarqube_db_user` from Task 1.
- Produces: `/etc/sonarqube/db_password` (mode `0600`, root-owned) and a
  registered fact `sonarqube_db_password` available to Task 3, which renders it
  into `sonarqube.env`. A PostgreSQL role and database both named `sonarqube`,
  reachable on `127.0.0.1:5432`.

- [ ] **Step 1: Add the collection to `requirements.yml`**

```yaml
---
collections:
  - name: community.general
    version: ">=8.3.0"
  - name: ansible.posix
    version: ">=1.5.4"
  # SonarQube has no embedded database. This is already present on Robert's
  # desktop but was never declared, which would have broken the recovery path
  # on any other machine.
  - name: community.postgresql
    version: ">=3.3.0"
```

- [ ] **Step 2: Add the failing assertions to `hosts/lab/verify.yml`**

Append to the sonarqube block created in Task 1:

```yaml
    - name: Read the PostgreSQL unit state
      ansible.builtin.command: systemctl is-enabled postgresql.service
      register: sonarqube_pg_enabled
      changed_when: false
      failed_when: false
      tags: [sonarqube]

    - name: Read whether PostgreSQL is running
      ansible.builtin.command: systemctl is-active postgresql.service
      register: sonarqube_pg_active
      changed_when: false
      failed_when: false
      tags: [sonarqube]

    - name: PostgreSQL starts at boot and is running
      ansible.builtin.assert:
        that:
          - sonarqube_pg_enabled.stdout == 'enabled'
          - sonarqube_pg_active.stdout == 'active'
        fail_msg: >-
          postgresql.service is enabled="{{ sonarqube_pg_enabled.stdout }}"
          active="{{ sonarqube_pg_active.stdout }}". SonarQube has no embedded
          database and will not start without it.
      tags: [sonarqube]

    # Connects as the sonarqube role over TCP with the generated password,
    # exactly as the service does. A `psql -U postgres` check would pass on
    # peer authentication and prove nothing about the path SonarQube uses.
    #
    # PGPASSWORD is read from the file rather than echoed, and the command
    # prints only the literal CONNECT_OK, so the password cannot reach the
    # Ansible log even with -vvv.
    - name: Probe the SonarQube database as the service role
      ansible.builtin.shell:
        cmd: >-
          PGPASSWORD="$(cat /etc/sonarqube/db_password)"
          psql -h 127.0.0.1 -U {{ sonarqube_db_user }}
          -d {{ sonarqube_db_name }} -tAc "select 'CONNECT_OK'"
      register: sonarqube_db_probe
      changed_when: false
      failed_when: false
      become: true
      tags: [sonarqube]

    # failed_when: false above, then assert on the OUTPUT. If the probe is
    # allowed to fail the task, a command that errors for an unrelated reason
    # (missing psql, unreadable password file) would stop the play with a
    # message about psql rather than about the database -- and an assertion
    # written the other way round, trusting a non-zero exit, once passed here
    # because the probe itself errored.
    - name: The SonarQube role can reach its own database over TCP
      ansible.builtin.assert:
        that:
          - "'CONNECT_OK' in sonarqube_db_probe.stdout"
        fail_msg: >-
          Could not connect to {{ sonarqube_db_name }} as
          {{ sonarqube_db_user }} on 127.0.0.1:5432.
          rc={{ sonarqube_db_probe.rc }},
          stderr="{{ sonarqube_db_probe.stderr | trim }}"
      tags: [sonarqube]
```

- [ ] **Step 3: Run the assertions and watch them fail**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags sonarqube
```

Expected: FAIL on "PostgreSQL starts at boot and is running" with
`enabled="<empty>"`, because no PostgreSQL is installed. Confirm the Task 1
assertions still pass above it.

- [ ] **Step 4: Add the database tasks to the role**

Append to `roles/sonarqube/tasks/main.yml`:

```yaml
# --- database ----------------------------------------------------------------
#
# SonarQube Community Build has no embedded database; PostgreSQL is mandatory.
# The fork's own shipped conf/sonar.properties:41 says "PostgreSQL 14 or
# greater" with no upper bound, and build.gradle:638 pins JDBC driver
# 42.7.13, which speaks the PG 18 protocol. Ubuntu 26.04 offers 18 only.
#
# Native rather than containerised: SonarQube is the only consumer, it keeps
# docker off the boot path for the service, and it keeps the password out of a
# compose file in a public repository.
- name: Install PostgreSQL
  ansible.builtin.apt:
    name:
      - postgresql
      # The community.postgresql modules talk to the server through this, on
      # the TARGET host. Without it every task below fails with
      # "the python psycopg2 module is required".
      - python3-psycopg2
    state: present

- name: Enable and start PostgreSQL
  ansible.builtin.systemd_service:
    name: postgresql
    enabled: true
    state: started

- name: Create the SonarQube config directory
  ansible.builtin.file:
    path: /etc/sonarqube
    state: directory
    owner: root
    group: root
    mode: "0755"

# Generated on the host and never rendered into the repository, which is
# public. Same shape as the SearXNG secret in roles/webstack: umask before the
# redirect so the file is never briefly world-readable, and `creates:` so a
# second apply does not roll the password and lock the service out of its own
# database.
- name: Generate the database password if it does not exist
  ansible.builtin.shell:
    cmd: umask 077 && openssl rand -hex 32 > /etc/sonarqube/db_password
    creates: /etc/sonarqube/db_password

- name: Read the database password
  ansible.builtin.slurp:
    src: /etc/sonarqube/db_password
  register: sonarqube_db_password_raw

- name: Record the database password
  ansible.builtin.set_fact:
    sonarqube_db_password: "{{ sonarqube_db_password_raw.content | b64decode | trim }}"
    # Keeps the value out of task output and out of -vvv logs. The password is
    # still in the fact, which is what the template needs; this only stops it
    # being printed.
    cacheable: false
  no_log: true

- name: Create the SonarQube database role
  community.postgresql.postgresql_user:
    name: "{{ sonarqube_db_user }}"
    password: "{{ sonarqube_db_password }}"
    role_attr_flags: NOSUPERUSER,NOCREATEDB,NOCREATEROLE
  become: true
  become_user: postgres
  no_log: true

# SonarQube requires UTF8 and a deterministic collation. It checks the
# encoding at startup and refuses a non-UTF8 database.
- name: Create the SonarQube database
  community.postgresql.postgresql_db:
    name: "{{ sonarqube_db_name }}"
    owner: "{{ sonarqube_db_user }}"
    encoding: UTF8
    template: template0
    lc_collate: C.UTF-8
    lc_ctype: C.UTF-8
  become: true
  become_user: postgres
```

- [ ] **Step 5: Apply and watch the assertions pass**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube
```

Expected: PostgreSQL installs and starts, the role and database are created,
and the probe returns `CONNECT_OK`.

If the probe fails with "no pg_hba.conf entry for host 127.0.0.1", Ubuntu's
default `pg_hba.conf` does not cover TCP password auth for this role. Add a
`community.postgresql.postgresql_pg_hba` task for
`host {{ sonarqube_db_name }} {{ sonarqube_db_user }} 127.0.0.1/32 scram-sha-256`
with a handler reloading PostgreSQL, and note in the role comment that it was
needed -- do not switch the service to peer auth or a unix socket to dodge it,
because the TCP path is what `SONAR_JDBC_URL` uses.

- [ ] **Step 6: Verify no password reached git**

```bash
git diff --cached | grep -iE "[a-f0-9]{32,}" && echo "SECRET IN DIFF -- STOP" || echo "clean"
```

Expected: `clean`. This repository is public and the password is 64 hex
characters; this is the check that it stayed on the host.

- [ ] **Step 7: Commit**

```bash
git add requirements.yml roles/sonarqube/tasks/main.yml hosts/lab/verify.yml
git commit -m "feat(sonarqube): PostgreSQL 18, database and generated password"
```

---

### Task 3: Service account, directories, and the two environment files

**Files:**
- Create: `roles/sonarqube/templates/sonarqube.env.j2`
- Create: `roles/sonarqube/templates/deploy.env.j2`
- Modify: `roles/sonarqube/tasks/main.yml`
- Modify: `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: every `sonarqube_*` variable from Task 1; the
  `sonarqube_db_password` fact from Task 2.
- Produces: user `sonarqube`; `/opt/sonarqube/{src,releases}`;
  `/data/sonarqube/{data,temp}`; `/var/log/sonarqube`;
  `/etc/sonarqube/sonarqube.env`; `/etc/sonarqube/deploy.env`. Task 4's script
  reads `deploy.env`; Task 5's unit reads `sonarqube.env`.

- [ ] **Step 1: Add the failing assertions to `hosts/lab/verify.yml`**

Append to the sonarqube block:

```yaml
    - name: Read the SonarQube service environment file
      ansible.builtin.slurp:
        src: /etc/sonarqube/sonarqube.env
      become: true
      register: sonarqube_env
      tags: [sonarqube]

    # Asserts the file agrees with vars.yml. Every key here is a real
    # ProcessProperties key put through the uppercase/underscore mapping in
    # SettingFormatter.java:32, so each one is checkable against the fork's
    # source rather than against folklore.
    #
    # SONAR_JDBC_PASSWORD is checked for PRESENCE only. Asserting its value
    # would require the password in this play's output.
    - name: The service environment matches this host
      ansible.builtin.assert:
        that:
          - "'SONAR_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/' ~ sonarqube_db_name in sonarqube_env_text"
          - "'SONAR_JDBC_USERNAME=' ~ sonarqube_db_user in sonarqube_env_text"
          - "'SONAR_JDBC_PASSWORD=' in sonarqube_env_text"
          - "'SONAR_PATH_DATA=' ~ sonarqube_data_dir ~ '/data' in sonarqube_env_text"
          - "'SONAR_PATH_TEMP=' ~ sonarqube_data_dir ~ '/temp' in sonarqube_env_text"
          - "'SONAR_PATH_LOGS=' ~ sonarqube_log_dir in sonarqube_env_text"
          - "'SONAR_WEB_PORT=' ~ sonarqube_port in sonarqube_env_text"
          - "'SONAR_TELEMETRY_ENABLE=false' in sonarqube_env_text"
        fail_msg: >-
          /etc/sonarqube/sonarqube.env does not match the variables in
          vars.yml.
      vars:
        sonarqube_env_text: "{{ sonarqube_env.content | b64decode }}"
      tags: [sonarqube]

    - name: Stat the service environment file
      ansible.builtin.stat:
        path: /etc/sonarqube/sonarqube.env
      register: sonarqube_env_stat
      tags: [sonarqube]

    # The file carries the database password, so it must not be world
    # readable. Group sonarqube so the service can read it; nobody else.
    - name: The service environment file is not world readable
      ansible.builtin.assert:
        that:
          - sonarqube_env_stat.stat.mode == '0640'
          - sonarqube_env_stat.stat.pw_name == 'root'
          - sonarqube_env_stat.stat.gr_name == sonarqube_user
        fail_msg: >-
          /etc/sonarqube/sonarqube.env is
          {{ sonarqube_env_stat.stat.mode }}
          {{ sonarqube_env_stat.stat.pw_name }}:{{ sonarqube_env_stat.stat.gr_name }},
          expected 0640 root:{{ sonarqube_user }}. It contains the database
          password.
      tags: [sonarqube]

    - name: Stat the state directories
      ansible.builtin.stat:
        path: "{{ item }}"
      register: sonarqube_dirs
      loop:
        - "{{ sonarqube_data_dir }}/data"
        - "{{ sonarqube_data_dir }}/temp"
        - "{{ sonarqube_log_dir }}"
        - "{{ sonarqube_root }}/releases"
      tags: [sonarqube]

    # Writable by the service account, because these are the only paths the
    # unit's ReadWritePaths names. If any of them is root-owned the service
    # starts and then dies on its first write.
    - name: The state directories exist and belong to the service account
      ansible.builtin.assert:
        that:
          - item.stat.exists
          - item.stat.isdir
          - item.stat.pw_name == sonarqube_user
        fail_msg: >-
          {{ item.item }} is missing or not owned by {{ sonarqube_user }}.
      loop: "{{ sonarqube_dirs.results }}"
      loop_control:
        label: "{{ item.item }}"
      tags: [sonarqube]

    - name: Stat the source checkout
      ansible.builtin.stat:
        path: "{{ sonarqube_root }}/src/.git"
      register: sonarqube_src
      tags: [sonarqube]

    - name: The fork is checked out and owned by robertcowher
      ansible.builtin.assert:
        that:
          - sonarqube_src.stat.exists
          - sonarqube_src.stat.pw_name == 'robertcowher'
        fail_msg: >-
          {{ sonarqube_root }}/src is not a checkout owned by robertcowher.
          It must be, so that building needs no sudo.
      tags: [sonarqube]
```

- [ ] **Step 2: Run the assertions and watch them fail**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags sonarqube
```

Expected: FAIL on "Read the SonarQube service environment file" -- the slurp
cannot find `/etc/sonarqube/sonarqube.env`. That is the right failure.

- [ ] **Step 3: Write the service environment template**

`roles/sonarqube/templates/sonarqube.env.j2`:

```
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
#
# Read by sonarqube.service as an EnvironmentFile. Every key is a real
# ProcessProperties key (server/sonar-process/.../ProcessProperties.java) run
# through SettingFormatter.fromJavaPropertyToEnvVariable: uppercased, with "."
# and "-" both becoming "_". So sonar.jdbc.url is SONAR_JDBC_URL.
#
# AppSettingsLoaderImpl.load() reads conf/sonar.properties first, then
# overrides from the environment, then from CLI arguments. Configuring here
# rather than in the release's conf/ file is what lets a deploy replace the
# whole release directory atomically: there is nothing in it to preserve.
#
# ONE key cannot be set this way: sonar.path.home. AppSettingsLoaderImpl:124
# forces it to the jar's own location AFTER the environment pass. That is
# wanted -- home is the release directory.
SONAR_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/{{ sonarqube_db_name }}
SONAR_JDBC_USERNAME={{ sonarqube_db_user }}
SONAR_JDBC_PASSWORD={{ sonarqube_db_password }}

# State, all outside {{ sonarqube_root }}/releases so that swapping releases
# touches none of it. sonar.path.data holds the Elasticsearch indices, which
# are derived from PostgreSQL -- deletable and rebuildable if a hard poweroff
# ever leaves them dirty.
SONAR_PATH_DATA={{ sonarqube_data_dir }}/data
SONAR_PATH_TEMP={{ sonarqube_data_dir }}/temp
SONAR_PATH_LOGS={{ sonarqube_log_dir }}

# All interfaces: the scanner and the browser both arrive from the LAN. ufw
# allows {{ sonarqube_port }} from lan_subnet only, which is what makes this
# private -- the bind does not.
SONAR_WEB_HOST=0.0.0.0
SONAR_WEB_PORT={{ sonarqube_port }}

# A private box should not report to anyone's analytics. The fork's own
# start.sh disables this for dev instances for the same reason.
SONAR_TELEMETRY_ENABLE=false
```

- [ ] **Step 4: Write the deploy environment template**

`roles/sonarqube/templates/deploy.env.j2`:

```
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
#
# Read by /usr/local/bin/sonarqube-deploy ONLY, never by the service. Kept
# separate from sonarqube.env on purpose: AppSettingsLoaderImpl warns about
# every key it does not recognise, so putting deploy policy in the service
# environment would fill the log with warnings about keys that are not
# SonarQube's business.
#
# No secrets here, hence 0644.
SONARQUBE_SRC={{ sonarqube_root }}/src
SONARQUBE_RELEASES={{ sonarqube_root }}/releases
SONARQUBE_CURRENT={{ sonarqube_root }}/current
SONARQUBE_USER={{ sonarqube_user }}
SONARQUBE_BRANCH={{ sonarqube_branch }}
SONARQUBE_KEEP_RELEASES={{ sonarqube_keep_releases }}
SONARQUBE_START_TIMEOUT={{ sonarqube_start_timeout }}
SONARQUBE_PORT={{ sonarqube_port }}
SONARQUBE_SERVICE=sonarqube.service
```

- [ ] **Step 5: Add the user, directory and clone tasks to the role**

Append to `roles/sonarqube/tasks/main.yml`:

```yaml
# --- service account and layout ----------------------------------------------
#
# A system account with no login and no home. Not in group ml: SonarQube reads
# nothing on /data except its own tree, and adding it to ml would hand a
# network-facing web server read access to every training checkpoint on the
# box for no reason at all.
- name: Create the SonarQube service user
  ansible.builtin.user:
    name: "{{ sonarqube_user }}"
    system: true
    create_home: false
    home: "{{ sonarqube_root }}"
    shell: /usr/sbin/nologin

# Owned by robertcowher, NOT the service account, so `git reset` and
# `./gradlew` from sonarqube-deploy need no sudo at all. Only the unpack, the
# symlink flip and the restart do. Same reasoning as /opt/bobgpt.
- name: Create the SonarQube tree
  ansible.builtin.file:
    path: "{{ sonarqube_root }}"
    state: directory
    owner: robertcowher
    group: "{{ sonarqube_user }}"
    mode: "0755"

# Unpacked releases, owned by the service account because that is what reads
# them. robertcowher writes here via sudo during a deploy.
- name: Create the releases directory
  ansible.builtin.file:
    path: "{{ sonarqube_root }}/releases"
    state: directory
    owner: "{{ sonarqube_user }}"
    group: "{{ sonarqube_user }}"
    mode: "0755"

- name: Create the state directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ sonarqube_user }}"
    group: "{{ sonarqube_user }}"
    mode: "0750"
  loop:
    - "{{ sonarqube_data_dir }}"
    - "{{ sonarqube_data_dir }}/data"
    - "{{ sonarqube_data_dir }}/temp"
    - "{{ sonarqube_log_dir }}"

# update: false is load-bearing, and it is the same lesson as /opt/bobgpt/src:
# sonarqube-deploy owns this checkout from here on, and an updating clone would
# reset it on every apply -- silently reverting a deploy that was testing a
# branch. This value decides only what a freshly provisioned host starts on.
- name: Bootstrap the fork checkout
  ansible.builtin.git:
    repo: "{{ sonarqube_repo }}"
    dest: "{{ sonarqube_root }}/src"
    version: "{{ sonarqube_branch }}"
    update: false
  become: true
  become_user: robertcowher

- name: Install the service environment file
  ansible.builtin.template:
    src: sonarqube.env.j2
    dest: /etc/sonarqube/sonarqube.env
    owner: root
    group: "{{ sonarqube_user }}"
    mode: "0640"
  no_log: true
  notify: Restart sonarqube

- name: Install the deploy environment file
  ansible.builtin.template:
    src: deploy.env.j2
    dest: /etc/sonarqube/deploy.env
    owner: root
    group: root
    mode: "0644"
```

Note `no_log: true` on the service environment template: without it, a
`--diff` run prints the rendered password to the terminal.

- [ ] **Step 6: Add the restart handler**

Append to `roles/sonarqube/handlers/main.yml`:

```yaml
# Unlike bobgpt's handler, this is an unconditional restart: SonarQube IS
# enabled at boot, so "already running" is the normal state and starting a
# stopped one is correct behaviour rather than a violation of a decision.
#
# It is a no-op before Task 5 installs the unit, because the handler only fires
# on a change and the unit does not exist yet -- if it fires anyway, systemd
# reports "Unit sonarqube.service not found" and the play fails loudly rather
# than quietly.
- name: Restart sonarqube
  ansible.builtin.systemd_service:
    name: sonarqube.service
    state: restarted
```

- [ ] **Step 7: Apply and watch the assertions pass**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube
```

The clone is large (SonarQube's history) and will take a few minutes. Expected:
all Task 1-3 assertions pass. The `Restart sonarqube` handler will fail here if
it fires, because the unit does not exist until Task 5; if that happens, that
is the expected loud failure -- proceed to Task 4 and 5, and re-run this apply
at the end of Task 5.

- [ ] **Step 8: Confirm no password reached git, then commit**

```bash
git add roles/sonarqube hosts/lab/verify.yml
git diff --cached | grep -iE "[a-f0-9]{32,}" && echo "SECRET IN DIFF -- STOP" || echo "clean"
git commit -m "feat(sonarqube): service account, layout, and the two env files"
```

---

### Task 4: The deploy script, test-driven

This is the only task with genuine unit tests, and they are the heart of the
plan. The script decides whether a deploy happened, whether it worked, and what
to do when it did not. Those decisions cannot be exercised by running real
20-minute builds, so they are driven against stubs.

**Files:**
- Create: `scripts/test_sonarqube_deploy.sh`
- Create: `roles/sonarqube/files/sonarqube-deploy`
- Create: `roles/sonarqube/files/sonarqube-run`
- Modify: `roles/sonarqube/tasks/main.yml`

**Interfaces:**
- Consumes: `/etc/sonarqube/deploy.env` from Task 3 (variables
  `SONARQUBE_SRC`, `SONARQUBE_RELEASES`, `SONARQUBE_CURRENT`,
  `SONARQUBE_USER`, `SONARQUBE_BRANCH`, `SONARQUBE_KEEP_RELEASES`,
  `SONARQUBE_START_TIMEOUT`, `SONARQUBE_PORT`, `SONARQUBE_SERVICE`).
- Produces: `/usr/local/bin/sonarqube-deploy` and
  `/usr/local/bin/sonarqube-run`. Task 5's unit calls `sonarqube-run`; Task 5's
  first-run task calls `sonarqube-deploy`. The script honours two test hooks:
  `SONARQUBE_DEPLOY_ENV` (path to the env file) and `SONARQUBE_SKIP_BUILD=1`
  (skip git and gradle, use whatever is already in `build/distributions`).

- [ ] **Step 1: Write the failing test harness**

`scripts/test_sonarqube_deploy.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for roles/sonarqube/files/sonarqube-deploy.
#
# The deploy script's risky decisions are the ones a real deploy almost never
# reaches: an ambiguous build artifact, a release that will not start, pruning
# a directory that is still live. Running real builds to reach them would take
# 20 minutes each and still would not let us MAKE a release fail to start, so
# everything the script touches outside its own tree is stubbed:
#
#   sudo       -> exec "$@", so file operations happen as the test user
#   systemctl  -> records the call and succeeds
#   curl       -> returns whatever status the test asked for
#   git        -> answers rev-parse with a fixed sha
#
# Modelled on scripts/test_idle_checks.sh. Run from the repository root:
#   ./scripts/test_sonarqube_deploy.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/roles/sonarqube/files/sonarqube-deploy"
PASS=0
FAIL=0

# --- harness ------------------------------------------------------------------

# Builds a throwaway world: a fake source tree, a releases dir, an env file,
# and stub executables ahead of the real ones on PATH. Echoes the root.
make_world() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/sqdeploy-test.XXXXXX")
  mkdir -p "$root/src/sonar-application/build/distributions"
  mkdir -p "$root/releases" "$root/bin"

  cat > "$root/deploy.env" <<EOF
SONARQUBE_SRC=$root/src
SONARQUBE_RELEASES=$root/releases
SONARQUBE_CURRENT=$root/current
SONARQUBE_USER=$(id -un)
SONARQUBE_BRANCH=master
SONARQUBE_KEEP_RELEASES=3
SONARQUBE_START_TIMEOUT=2
SONARQUBE_PORT=9000
SONARQUBE_SERVICE=sonarqube.service
EOF

  # sudo: run the command directly. The test user owns the temp tree, so every
  # chown/mv/rm the script performs works without privilege.
  cat > "$root/bin/sudo" <<'EOF'
#!/bin/sh
# Drop any leading options sudo would accept, then exec the command.
while [ $# -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF

  # systemctl: record and succeed. The script must not care what it does.
  cat > "$root/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$root/systemctl.log"
exit 0
EOF

  # curl: answer /api/system/status with the contents of status.txt, so a test
  # can decide whether the service "came up". An absent file means no answer
  # at all, which is what a dead service looks like.
  cat > "$root/bin/curl" <<EOF
#!/bin/sh
if [ -r "$root/status.txt" ]; then
  cat "$root/status.txt"
  exit 0
fi
exit 7
EOF

  # git: only rev-parse matters to the script when the build is skipped.
  cat > "$root/bin/git" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "rev-parse" ]; then echo "deadbee"; exit 0; fi
done
exit 0
EOF

  chmod +x "$root/bin"/*
  echo "$root"
}

# Writes a zip that unpacks to a single sonarqube-<version>/ directory, the
# shape :sonar-application:zip produces.
make_zip() {
  local root=$1 version=$2
  local stage
  stage=$(mktemp -d "${TMPDIR:-/tmp}/sqzip.XXXXXX")
  mkdir -p "$stage/sonarqube-$version/lib"
  : > "$stage/sonarqube-$version/lib/sonar-application-$version.jar"
  (cd "$stage" && zip -qr \
    "$root/src/sonar-application/build/distributions/sonarqube-$version.zip" \
    "sonarqube-$version")
  rm -rf "$stage"
}

run_deploy() {
  local root=$1
  PATH="$root/bin:$PATH" \
  SONARQUBE_DEPLOY_ENV="$root/deploy.env" \
  SONARQUBE_SKIP_BUILD=1 \
    "$SCRIPT" 2>&1
}

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' \
      "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# --- tests --------------------------------------------------------------------

# A build that produced nothing must stop. Deploying "whatever is there" after
# a silent build failure would serve stale code and report success.
test_no_zip() {
  local root out rc
  root=$(make_world)
  out=$(run_deploy "$root"); rc=$?
  check "no zip: exits non-zero" "nonzero" "$([ $rc -ne 0 ] && echo nonzero || echo zero)"
  check "no zip: says so" "yes" "$(echo "$out" | grep -qi "no zip" && echo yes || echo no)"
  rm -rf "$root"
}

# Review Focus 1. Two artifacts is ambiguous, and "newest wins" would deploy
# the wrong code without ever saying so.
test_two_zips() {
  local root out rc
  root=$(make_world)
  make_zip "$root" "26.11"
  make_zip "$root" "26.12"
  out=$(run_deploy "$root"); rc=$?
  check "two zips: exits non-zero" "nonzero" "$([ $rc -ne 0 ] && echo nonzero || echo zero)"
  check "two zips: refuses to choose" "yes" \
    "$(echo "$out" | grep -qi "found 2" && echo yes || echo no)"
  check "two zips: nothing deployed" "no" \
    "$([ -e "$root/current" ] && echo yes || echo no)"
  rm -rf "$root"
}

# The happy path, and the naming contract later tasks depend on: the release
# directory is <version>-<shortsha> and current points at it.
test_happy_path() {
  local root out rc
  root=$(make_world)
  make_zip "$root" "26.11"
  echo '{"status":"UP"}' > "$root/status.txt"
  out=$(run_deploy "$root"); rc=$?
  check "happy: exits zero" "zero" "$([ $rc -eq 0 ] && echo zero || echo nonzero)"
  check "happy: release named version-sha" "yes" \
    "$([ -d "$root/releases/26.11-deadbee" ] && echo yes || echo no)"
  check "happy: current points at it" "$root/releases/26.11-deadbee" \
    "$(readlink -f "$root/current")"
  check "happy: restarted the service" "yes" \
    "$(grep -q "restart sonarqube.service" "$root/systemctl.log" && echo yes || echo no)"
  rm -rf "$root"
}

# Review Focus 2. A release that builds but will not start must leave the
# PREVIOUS release serving. A deploy that takes the box down is worse than one
# that refuses to deploy.
test_rollback() {
  local root out rc
  root=$(make_world)

  # First deploy, succeeds.
  make_zip "$root" "26.11"
  echo '{"status":"UP"}' > "$root/status.txt"
  run_deploy "$root" > /dev/null

  # Second deploy of a different version, never reaches UP.
  rm -f "$root"/src/sonar-application/build/distributions/*.zip
  make_zip "$root" "26.12"
  echo '{"status":"STARTING"}' > "$root/status.txt"
  out=$(run_deploy "$root"); rc=$?

  check "rollback: exits non-zero" "nonzero" "$([ $rc -ne 0 ] && echo nonzero || echo zero)"
  check "rollback: current is back on the old release" \
    "$root/releases/26.11-deadbee" "$(readlink -f "$root/current")"
  check "rollback: said it rolled back" "yes" \
    "$(echo "$out" | grep -qi "rolling back" && echo yes || echo no)"
  rm -rf "$root"
}

# Review Focus 3. On a FIRST deploy there is nothing to roll back to. The
# script must fail loudly and must not leave current pointing at a release
# that cannot run -- a dangling current would make the next deploy's rollback
# target garbage.
test_first_deploy_failure() {
  local root out rc
  root=$(make_world)
  make_zip "$root" "26.11"
  echo '{"status":"DOWN"}' > "$root/status.txt"
  out=$(run_deploy "$root"); rc=$?
  check "first failure: exits non-zero" "nonzero" "$([ $rc -ne 0 ] && echo nonzero || echo zero)"
  check "first failure: no rollback claimed" "no" \
    "$(echo "$out" | grep -qi "rolling back" && echo yes || echo no)"
  check "first failure: current is not left in place" "no" \
    "$([ -L "$root/current" ] && echo yes || echo no)"
  rm -rf "$root"
}

# Review Focus 4. Pruning keeps KEEP releases AND the live one unconditionally.
# Redeploying an older sha makes the live directory not the newest; deleting it
# would delete the running server's own jars.
test_prune_spares_live() {
  local root
  root=$(make_world)
  make_zip "$root" "26.11"
  echo '{"status":"UP"}' > "$root/status.txt"
  run_deploy "$root" > /dev/null

  # Four decoys, all newer than the live release.
  for v in 90.1 90.2 90.3 90.4; do
    mkdir -p "$root/releases/$v-aaaaaaa"
    touch "$root/releases/$v-aaaaaaa"
  done
  # Re-run the deploy so pruning happens with the live release being oldest.
  run_deploy "$root" > /dev/null

  check "prune: live release survives" "yes" \
    "$([ -d "$root/releases/26.11-deadbee" ] && echo yes || echo no)"
  check "prune: current still resolves" "yes" \
    "$([ -d "$(readlink -f "$root/current")" ] && echo yes || echo no)"
  check "prune: kept at most 4 dirs (3 + live)" "yes" \
    "$([ "$(find "$root/releases" -maxdepth 1 -mindepth 1 -type d | wc -l)" -le 4 ] && echo yes || echo no)"
  rm -rf "$root"
}

test_no_zip
test_two_zips
test_happy_path
test_rollback
test_first_deploy_failure
test_prune_spares_live

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the tests and watch every one fail**

```bash
chmod +x scripts/test_sonarqube_deploy.sh
./scripts/test_sonarqube_deploy.sh
```

Expected: every test FAILs, because `roles/sonarqube/files/sonarqube-deploy`
does not exist yet. The output will show the harness itself working -- if
instead it errors before printing any `FAIL` line, fix the harness first. Also
confirm `zip` is available locally (`which zip`); `make_zip` needs it.

- [ ] **Step 3: Write the deploy script**

`roles/sonarqube/files/sonarqube-deploy`:

```bash
#!/usr/bin/env bash
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
#
# Build Robert's SonarQube fork from source and swap the running release to it.
#
# Run as robertcowher, who owns the checkout (so git and gradle need no
# privilege) and has passwordless sudo on this host (used only for the unpack,
# the symlink flip and the restart):
#
#     ssh lab sonarqube-deploy
#
# The order matters and is the point of the whole script: the build completes
# BEFORE anything is swapped, so a broken commit cannot take down a running
# server, and a release that builds but will not start is rolled back
# automatically.
#
# Tested by scripts/test_sonarqube_deploy.sh. Two hooks exist for that harness
# and for nothing else: SONARQUBE_DEPLOY_ENV points at an alternative env file,
# and SONARQUBE_SKIP_BUILD=1 skips git and gradle.
set -euo pipefail

ENV_FILE=${SONARQUBE_DEPLOY_ENV:-/etc/sonarqube/deploy.env}
if [ -r "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
fi

SRC=${SONARQUBE_SRC:-/opt/sonarqube/src}
RELEASES=${SONARQUBE_RELEASES:-/opt/sonarqube/releases}
CURRENT=${SONARQUBE_CURRENT:-/opt/sonarqube/current}
USER_NAME=${SONARQUBE_USER:-sonarqube}
BRANCH=${SONARQUBE_BRANCH:-master}
KEEP=${SONARQUBE_KEEP_RELEASES:-3}
TIMEOUT=${SONARQUBE_START_TIMEOUT:-300}
PORT=${SONARQUBE_PORT:-9000}
SERVICE=${SONARQUBE_SERVICE:-sonarqube.service}
SKIP_BUILD=${SONARQUBE_SKIP_BUILD:-0}

DIST="$SRC/sonar-application/build/distributions"

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# --- build -------------------------------------------------------------------

if [ "$SKIP_BUILD" != "1" ]; then
  log "resetting $SRC to origin/$BRANCH"
  git -C "$SRC" fetch --prune origin
  # A reset rather than a pull: this is a deploy checkout, not a work tree, so
  # it should match the remote exactly and never need a merge.
  git -C "$SRC" reset --hard "origin/$BRANCH"

  # Clearing first is what makes the single-zip check below meaningful. Without
  # it, yesterday's artifact sits next to today's and the deploy becomes a
  # guess.
  log "clearing $DIST"
  rm -rf "$DIST"

  log "building :sonar-application:zip (this takes a while)"
  (cd "$SRC" && ./gradlew --console=plain :sonar-application:zip)
fi

# --- identify the artifact ---------------------------------------------------

shopt -s nullglob
zips=("$DIST"/sonarqube-*.zip)
shopt -u nullglob

if [ ${#zips[@]} -eq 0 ]; then
  die "no zip in $DIST -- did the build actually produce one?"
fi
if [ ${#zips[@]} -gt 1 ]; then
  # Deliberately NOT "take the newest". Two artifacts means the state of the
  # build directory is not understood, and deploying one of them would look
  # like success while serving the wrong code.
  die "expected one zip in $DIST, found ${#zips[@]}: ${zips[*]}"
fi
ZIP=${zips[0]}
log "artifact $ZIP"

SHA=$(git -C "$SRC" rev-parse --short HEAD)

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sonarqube-deploy.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

unzip -q "$ZIP" -d "$STAGE"

shopt -s nullglob
unpacked=("$STAGE"/sonarqube-*/)
shopt -u nullglob
[ ${#unpacked[@]} -eq 1 ] || \
  die "expected one directory inside $ZIP, found ${#unpacked[@]}"

# The version is read from the artifact itself, never declared anywhere in the
# Ansible repository.
VERSION=$(basename "${unpacked[0]}")
VERSION=${VERSION#sonarqube-}
RELEASE="$RELEASES/$VERSION-$SHA"
log "release $VERSION-$SHA"

# --- swap --------------------------------------------------------------------

PREVIOUS=""
if [ -L "$CURRENT" ]; then
  PREVIOUS=$(readlink -f "$CURRENT")
  log "previous release $PREVIOUS"
fi

point_at() {
  # Two steps, not one: `ln -sfn` onto an existing symlink that points at a
  # DIRECTORY creates a link inside it instead of replacing it. Writing a new
  # name and renaming it over the old one is both correct and atomic, so there
  # is never an instant where $CURRENT does not exist.
  sudo ln -sfn "$1" "$CURRENT.new"
  sudo mv -T "$CURRENT.new" "$CURRENT"
}

sudo rm -rf "$RELEASE"
sudo mkdir -p "$RELEASES"
sudo mv "${unpacked[0]}" "$RELEASE"
sudo chown -R "$USER_NAME:$USER_NAME" "$RELEASE"

point_at "$RELEASE"
log "restarting $SERVICE"
sudo systemctl restart "$SERVICE"

# --- prove it came up --------------------------------------------------------

wait_up() {
  local deadline status
  deadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(curl -fsS "http://127.0.0.1:$PORT/api/system/status" 2>/dev/null \
      | sed -n 's/.*"status" *: *"\([A-Z]*\)".*/\1/p')
    if [ "$status" = "UP" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

if wait_up; then
  log "UP on $VERSION-$SHA"
else
  log "did not reach UP within ${TIMEOUT}s"
  if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ] && [ "$PREVIOUS" != "$RELEASE" ]; then
    log "rolling back to $PREVIOUS"
    point_at "$PREVIOUS"
    sudo systemctl restart "$SERVICE"
    if wait_up; then
      log "rolled back and UP"
    else
      log "rollback did NOT come up either -- check journalctl -u $SERVICE"
    fi
    die "deploy of $VERSION-$SHA failed; rolled back to $PREVIOUS"
  fi
  # Nothing to roll back to. Remove the symlink rather than leave it pointing
  # at a release that cannot run: a dangling current would become the next
  # deploy's rollback target, which would quietly make the next failure
  # unrecoverable too.
  log "no previous release to roll back to; removing $CURRENT"
  sudo rm -f "$CURRENT"
  die "deploy of $VERSION-$SHA failed and there was nothing to roll back to"
fi

# --- prune -------------------------------------------------------------------

LIVE=$(readlink -f "$CURRENT")
# Newest first, then skip the ones we keep. The live release is spared
# unconditionally below, because it is not necessarily the newest: redeploying
# an older sha puts the running release behind newer directories.
mapfile -t stale < <(ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n "+$((KEEP + 1))")
for dir in "${stale[@]:-}"; do
  [ -n "$dir" ] || continue
  if [ "$(readlink -f "$dir")" = "$LIVE" ]; then
    log "keeping $dir (live)"
    continue
  fi
  log "pruning $dir"
  sudo rm -rf "$dir"
done

log "done"
```

- [ ] **Step 4: Run the tests until they all pass**

```bash
./scripts/test_sonarqube_deploy.sh
```

Expected: `18 passed, 0 failed`. Fix the script, not the tests, unless a test
is asserting something the spec does not ask for.

- [ ] **Step 5: Write the run wrapper**

`roles/sonarqube/files/sonarqube-run`:

```bash
#!/usr/bin/env bash
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
#
# ExecStart for sonarqube.service. This wrapper exists for exactly one reason:
# the application jar's name carries the version
# (lib/sonar-application-26.11.jar) and systemd's ExecStart does not expand
# globs. Putting the glob here keeps the version out of the unit file, which is
# what lets a deploy change versions without re-templating anything.
set -euo pipefail

HOME_DIR=${SONARQUBE_HOME:-/opt/sonarqube/current}

shopt -s nullglob
jars=("$HOME_DIR"/lib/sonar-application-*.jar)
shopt -u nullglob

if [ ${#jars[@]} -ne 1 ]; then
  echo "expected exactly one sonar-application jar in $HOME_DIR/lib, found ${#jars[@]}" >&2
  exit 1
fi

# exec, so systemd tracks the JVM itself as the main process rather than this
# shell. Without it, a stop would signal bash and leave the JVM behind.
exec java -jar "${jars[0]}"
```

- [ ] **Step 6: Install both scripts from the role**

Append to `roles/sonarqube/tasks/main.yml`:

```yaml
# --- deploy tooling ----------------------------------------------------------
- name: Install the deploy script
  ansible.builtin.copy:
    src: sonarqube-deploy
    dest: /usr/local/bin/sonarqube-deploy
    owner: root
    group: root
    mode: "0755"

- name: Install the run wrapper
  ansible.builtin.copy:
    src: sonarqube-run
    dest: /usr/local/bin/sonarqube-run
    owner: root
    group: root
    mode: "0755"
```

- [ ] **Step 7: Commit**

```bash
git add scripts/test_sonarqube_deploy.sh roles/sonarqube
git commit -m "feat(sonarqube): deploy script with rollback, and its tests

Six test cases against stubbed sudo/systemctl/curl/git, covering the
decisions a real deploy almost never reaches: an empty build directory,
two artifacts (must abort rather than pick one), the happy path, a
release that builds but will not start (must roll back), a first deploy
that fails with nothing to roll back to (must not leave current
dangling), and pruning sparing the live release even when it is oldest."
```

---

### Task 5: The systemd unit, and the first real build

**Files:**
- Create: `roles/sonarqube/templates/sonarqube.service.j2`
- Modify: `roles/sonarqube/tasks/main.yml`
- Modify: `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `/etc/sonarqube/sonarqube.env` (Task 3),
  `/usr/local/bin/sonarqube-run` and `/usr/local/bin/sonarqube-deploy`
  (Task 4).
- Produces: `sonarqube.service`, enabled and active, serving on
  `{{ sonarqube_port }}`; `/opt/sonarqube/current` pointing at a release.

- [ ] **Step 1: Add the failing assertions to `hosts/lab/verify.yml`**

Append to the sonarqube block:

```yaml
    - name: Read the SonarQube unit state
      ansible.builtin.command: systemctl is-enabled sonarqube.service
      register: sonarqube_enabled_state
      changed_when: false
      failed_when: false
      tags: [sonarqube]

    - name: Read whether SonarQube is running
      ansible.builtin.command: systemctl is-active sonarqube.service
      register: sonarqube_active_state
      changed_when: false
      failed_when: false
      tags: [sonarqube]

    # Unlike bobgpt, this one IS enabled: Robert's decision, so it is simply
    # there each morning rather than costing 60-90s of Elasticsearch startup
    # whenever he wants to scan.
    - name: SonarQube starts at boot and is running
      ansible.builtin.assert:
        that:
          - sonarqube_enabled_state.stdout == 'enabled'
          - sonarqube_active_state.stdout == 'active'
        fail_msg: >-
          sonarqube.service is enabled="{{ sonarqube_enabled_state.stdout }}"
          active="{{ sonarqube_active_state.stdout }}", expected
          enabled/active.
      tags: [sonarqube]

    - name: Read the Elasticsearch bootstrap limits from the unit
      ansible.builtin.command: >-
        systemctl show sonarqube.service -p LimitNOFILE -p LimitNPROC
      register: sonarqube_limits
      changed_when: false
      tags: [sonarqube]

    # Bundled Elasticsearch bootstrap-checks both of these and refuses to start
    # if they are too low. They are easy to drop in a unit rewrite and the
    # failure appears as an opaque ES startup error, so assert them directly.
    - name: The unit raises the limits Elasticsearch checks
      ansible.builtin.assert:
        that:
          - "'LimitNOFILE=131072' in sonarqube_limits.stdout"
          - "'LimitNPROC=8192' in sonarqube_limits.stdout"
        fail_msg: >-
          sonarqube.service limits are wrong:
          {{ sonarqube_limits.stdout | trim }}
      tags: [sonarqube]

    - name: Ask SonarQube for its status
      ansible.builtin.uri:
        url: "http://127.0.0.1:{{ sonarqube_port }}/api/system/status"
        return_content: true
      register: sonarqube_status
      failed_when: false
      tags: [sonarqube]

    # Liveness, not "a process exists". Three JVMs can be up with the web
    # server refusing every request, and systemctl is-active would still say
    # active.
    - name: SonarQube reports itself UP
      ansible.builtin.assert:
        that:
          - sonarqube_status.status == 200
          - sonarqube_status.json.status == 'UP'
        fail_msg: >-
          /api/system/status did not report UP:
          status={{ sonarqube_status.status | default('none') }}
          body={{ sonarqube_status.content | default('') | trim }}
      tags: [sonarqube]

    - name: Resolve the current release symlink
      ansible.builtin.stat:
        path: "{{ sonarqube_root }}/current"
      register: sonarqube_current
      tags: [sonarqube]

    - name: Ask SonarQube for its version
      ansible.builtin.uri:
        url: "http://127.0.0.1:{{ sonarqube_port }}/api/server/version"
        return_content: true
      register: sonarqube_version
      failed_when: false
      tags: [sonarqube]

    # The assertion that earns its keep. The release directory is
    # <version>-<shortsha>, so the version the running JVM reports must be the
    # prefix of the directory current points at. This is the only check that
    # catches a flipped symlink with a stale process still serving -- a state
    # in which every other assertion here passes and the box is quietly
    # running code nobody thinks is deployed.
    - name: The serving version matches the release the symlink points at
      ansible.builtin.assert:
        that:
          - sonarqube_current.stat.exists
          - sonarqube_current.stat.islnk
          - sonarqube_version.status == 200
          - >-
            (sonarqube_current.stat.lnk_target | basename)
            is match('^' ~ (sonarqube_version.content | trim | regex_escape) ~ '-')
        fail_msg: >-
          /api/server/version reports
          "{{ sonarqube_version.content | default('') | trim }}" but
          {{ sonarqube_root }}/current points at
          "{{ sonarqube_current.stat.lnk_target | default('nothing') }}".
          The symlink was flipped without the service picking it up, or the
          release was renamed.
      tags: [sonarqube]

    - name: Find the community branch plugin in the live release
      ansible.builtin.find:
        paths: "{{ sonarqube_root }}/current/lib/extensions"
        patterns: "sonar-community-branch-plugin-*.jar"
        follow: true
      register: sonarqube_branch_plugin
      tags: [sonarqube]

    # The reason the fork exists. It is declared in
    # sonar-application/bundled_plugins.gradle and the build copies every
    # bundledPlugin into lib/extensions/ (sonar-application/build.gradle:445),
    # which is why that is the path searched here. If the jar is missing the
    # build did not include it, and branch analysis would fail at scan time
    # with a confusing error rather than here.
    - name: The community branch plugin is bundled in the live release
      ansible.builtin.assert:
        that:
          - sonarqube_branch_plugin.matched == 1
        fail_msg: >-
          Expected exactly one sonar-community-branch-plugin jar in
          {{ sonarqube_root }}/current/lib/extensions, found
          {{ sonarqube_branch_plugin.matched }}. The fork's branch analysis
          will not work.
      tags: [sonarqube]
```

- [ ] **Step 2: Run the assertions and watch them fail**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags sonarqube
```

Expected: FAIL on "SonarQube starts at boot and is running" with an empty
`enabled`, because the unit does not exist yet.

- [ ] **Step 3: Write the unit template**

`roles/sonarqube/templates/sonarqube.service.j2`:

```
# Managed by Ansible. See roles/sonarqube/tasks/main.yml.
[Unit]
Description=SonarQube (Robert's fork, built from source)
Documentation=https://github.com/bobcowher/sonarqube
# SonarQube Community Build has no embedded database and exits on startup if it
# cannot reach PostgreSQL, so this is a real ordering requirement rather than a
# nicety.
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User={{ sonarqube_user }}
Group={{ sonarqube_user }}
# Home is the release directory: AppSettingsLoaderImpl detects it from the
# jar's own location and forces sonar.path.home to it, so this only needs to be
# somewhere the process can sit.
WorkingDirectory={{ sonarqube_root }}/current
EnvironmentFile=/etc/sonarqube/sonarqube.env
# The wrapper globs for the jar under this directory. Passed explicitly rather
# than left to the wrapper's built-in default, so that changing sonarqube_root
# in vars.yml cannot leave the unit and the wrapper disagreeing about where the
# release lives.
Environment=SONARQUBE_HOME={{ sonarqube_root }}/current

# A wrapper, because the jar name carries the version and ExecStart cannot
# glob. Keeping the glob out of here is what lets a deploy change versions
# without re-templating the unit.
ExecStart=/usr/local/bin/sonarqube-run

# Unlike bobgpt, this service is enabled and expected to be up, so a crash
# should be recovered rather than left visible. 30s because a restart means
# three JVMs and an Elasticsearch start; a tighter interval would just thrash.
Restart=on-failure
RestartSec=30

# Elasticsearch runs bootstrap checks against both of these at startup and
# refuses to start if they are too low. The third such check is
# vm.max_map_count, set by /etc/sysctl.d/99-sonarqube.conf.
LimitNOFILE=131072
LimitNPROC=8192

# Cold start is Elasticsearch plus two JVMs plus any pending database
# migration, so systemd must not give up before SonarQube has had a chance.
TimeoutStartSec=300
# Shutting down means flushing Elasticsearch. Killing it early is what leaves a
# dirty index to rebuild on the next boot, and this box powers off nightly.
TimeoutStopSec=180

# The whole filesystem is read-only except what is named below. A
# network-facing web server on a box whose other tenant is training
# checkpoints should not be able to write outside its own tree.
ProtectSystem=strict
ProtectHome=true
# NOT PrivateTmp: sonar.path.temp is relocated to the data directory below, so
# a private /tmp would only hide where the real scratch space is.
PrivateTmp=false
ReadWritePaths={{ sonarqube_data_dir }} {{ sonarqube_log_dir }}
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Add the unit and first-build tasks to the role**

Append to `roles/sonarqube/tasks/main.yml`:

```yaml
# --- service -----------------------------------------------------------------
- name: Install the service unit
  ansible.builtin.template:
    src: sonarqube.service.j2
    dest: /etc/systemd/system/sonarqube.service
    owner: root
    group: root
    mode: "0644"
  notify: Restart sonarqube

- name: Check whether a release is already deployed
  ansible.builtin.stat:
    path: "{{ sonarqube_root }}/current"
  register: sonarqube_current_link

# This is what makes the recovery claim literal: on a bare host, ONE playbook
# run installs the toolchain, the database and the checkout and then builds and
# starts the fork. Guarded on the symlink's absence, so a normal apply never
# triggers a 20-minute Gradle build -- deploys are sonarqube-deploy's job from
# then on.
#
# Run as robertcowher: they own the checkout, so git and gradle need no
# privilege, and the script sudoes for the three steps that do.
- name: Build and deploy the fork if nothing is deployed yet
  ansible.builtin.command: /usr/local/bin/sonarqube-deploy
  become: true
  become_user: robertcowher
  when: not sonarqube_current_link.stat.exists
  changed_when: true
  # A source build of SonarQube from a cold Gradle cache. Generous on purpose:
  # a timeout here leaves a half-deployed host, which is worse than waiting.
  async: 5400
  poll: 30

- name: Enable and start SonarQube
  ansible.builtin.systemd_service:
    name: sonarqube.service
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 5: Apply, and expect the first build to take a long time**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube
```

This is the first real build: a cold Gradle cache, the web application, and
every bundled analyzer. Budget 20-45 minutes and watch it rather than walking
away, because this is where the spec's open questions get answered.

**If it fails, the three expected causes, in order of likelihood:**

1. **The Gradle build needs a Node version lab's system `node` does not
   satisfy.** The web build may fetch its own toolchain; if it does not, the
   error names a Node version. Fix by adding the required `nodejs` to the
   role's apt list, or by letting the Gradle node plugin download its own --
   whichever the error points at. Record which in a role comment.
2. **PostgreSQL 18 is refused by the dialect check.** The log will say so
   explicitly at startup. **Say so plainly rather than working around it**,
   then switch to a pinned `postgres:17` container per the spec's fallback and
   update the spec's "PostgreSQL 18" decision to record what actually
   happened.
3. **`ProtectSystem=strict` blocks a path Elasticsearch needs.** The journal
   will name a read-only filesystem error with the path. Add that path to
   `ReadWritePaths` **and write a comment in the unit saying what forced it**.
   Do not relax `ProtectSystem` wholesale.

- [ ] **Step 6: Watch the assertions pass**

The apply imports `verify.yml` automatically. Expected: every sonarqube
assertion passes, including the version-matches-symlink check and the branch
plugin being found.

Then confirm by hand that the version came from the artifact and not from
anything in this repository:

```bash
ssh lab 'readlink /opt/sonarqube/current; curl -s localhost:9000/api/server/version; echo'
grep -rn "26\.11" --include="*.yml" --include="*.j2" roles/sonarqube hosts/lab/ \
  && echo "VERSION LEAKED INTO THE REPO -- fix it" || echo "no version in the repo, correct"
```

- [ ] **Step 7: Commit**

```bash
git add roles/sonarqube hosts/lab/verify.yml
git commit -m "feat(sonarqube): systemd unit, and build on first provision"
```

---

### Task 6: Firewall and the Caddy route

**Files:**
- Modify: `roles/firewall/tasks/main.yml`
- Modify: `roles/webstack/templates/Caddyfile.j2`
- Modify: `hosts/lab/verify.yml`

**Interfaces:**
- Consumes: `sonarqube_port` from Task 1.
- Produces: port 9000 reachable from `lan_subnet`; `http://lab.local/sonar`
  redirecting to `http://lab.local:9000/`.

- [ ] **Step 1: Add the failing assertion to `hosts/lab/verify.yml`**

Append to the sonarqube block:

```yaml
    - name: Read the ufw rules
      ansible.builtin.command: ufw status
      become: true
      register: sonarqube_ufw
      changed_when: false
      tags: [sonarqube]

    # Only from the LAN. Deliberately NO docker_bridge_subnet rule: nothing in
    # a container talks to SonarQube, unlike bobgpt and llama-swap, so that
    # rule would be real surface for no gain. If something containerised ever
    # needs to scan, add it then and say why.
    - name: SonarQube is reachable from the LAN and nowhere else
      ansible.builtin.assert:
        that:
          - sonarqube_ufw.stdout is search(sonarqube_port | string ~ '/tcp\s+ALLOW\s+' ~ (lan_subnet | regex_escape))
          - not (sonarqube_ufw.stdout is search(sonarqube_port | string ~ '/tcp\s+ALLOW\s+Anywhere'))
        fail_msg: >-
          ufw does not allow {{ sonarqube_port }}/tcp from {{ lan_subnet }}
          only. Rules:
          {{ sonarqube_ufw.stdout }}
      tags: [sonarqube]
```

- [ ] **Step 2: Run it and watch it fail**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml --tags sonarqube
```

Expected: FAIL on "SonarQube is reachable from the LAN and nowhere else",
because no rule for 9000 exists.

- [ ] **Step 3: Add the firewall rule**

In `roles/firewall/tasks/main.yml`, extend the "Allow the native LAN services"
loop:

```yaml
- name: Allow the native LAN services
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
    src: "{{ lan_subnet }}"
  loop:
    - "8080"   # llama-swap
    - "5000"   # beekeeper
    - "{{ bobgpt_port }}"   # bobgpt, for curling it from the desktop
    # SonarQube. The browser and the scanner both come from the LAN, and both
    # use this one port -- which is why the Caddy entry below is a redirect
    # rather than a proxy.
    - "{{ sonarqube_port }}"
```

No `docker_bridge_subnet` rule is added. The two that exist (llama-swap,
bobgpt) are there because Open WebUI reaches those services from inside a
container; nothing reaches SonarQube that way.

- [ ] **Step 4: Add the Caddy redirect**

In `roles/webstack/templates/Caddyfile.j2`, insert after the beekeeper block
and before the final `handle`:

```
	# SonarQube is NOT proxied, for a different reason than beekeeper. It
	# supports subpath hosting properly via sonar.web.context, so a proxy
	# would work -- but setting a context path makes the browser URL and the
	# scanner URL different strings, and getting the scanner URL wrong is a
	# confusing failure. One URL for both is worth more than one fewer port.
	redir /sonar /sonar/
	handle /sonar/* {
		redir http://lab.local:{{ sonarqube_port }}/ 302
	}
```

- [ ] **Step 5: Apply and watch the assertion pass**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags firewall,webstack,sonarqube
```

- [ ] **Step 6: Confirm reachability from the desktop, not just from lab**

The assertion above reads ufw's own rules, which proves configuration, not
reachability. Check the real path from this machine:

```bash
curl -fsS http://lab.local:9000/api/system/status; echo
curl -fsS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://lab.local/sonar/
```

Expected: `{"id":"...","version":"...","status":"UP"}` and a `302` whose
redirect URL is `http://lab.local:9000/`.

- [ ] **Step 7: Commit**

```bash
git add roles/firewall/tasks/main.yml roles/webstack/templates/Caddyfile.j2 hosts/lab/verify.yml
git commit -m "feat(sonarqube): open 9000 to the LAN and redirect /sonar"
```

---

### Task 7: The scanner, and an end-to-end branch-analysis smoke test

**Files:**
- Create: `scripts/smoke_sonarqube.sh`
- Modify: `hosts/lab/vars.yml`
- Modify: `roles/sonarqube/tasks/main.yml`

**Interfaces:**
- Consumes: a running SonarQube from Task 5, reachable per Task 6.
- Produces: `sonar-scanner` on lab at
  `/opt/sonar-scanner/bin/sonar-scanner`, symlinked to
  `/usr/local/bin/sonar-scanner`; `scripts/smoke_sonarqube.sh`, run by hand
  with a token.

- [ ] **Step 1: Add the scanner variables to `hosts/lab/vars.yml`**

The version and checksum below were resolved and verified on 2026-10-12, so
there is nothing to look up: `8.1.0.6389` was the current
`sonar-scanner-cli` release, the artifact is 61626644 bytes, and the zip
unpacks to a single `sonar-scanner-8.1.0.6389-linux-x64/` directory carrying
its own JRE (so the scanner needs no system Java).

Append to the sonarqube block:

```yaml
# The CLI scanner, on lab so that scripts/smoke_sonarqube.sh can run on the
# box itself rather than depending on a working desktop. Pinned by version AND
# sha256 -- the llama_swap_version precedent -- because this is a third-party
# binary, unlike the fork, which is built from source Robert controls.
#
# Robert normally scans from the desktop; this exists for validation, and
# scanning from lab is a side benefit. The zip bundles its own JRE, so this
# does not depend on the host's Java 21.
#
# To move it: download the new zip, sha256sum it, and change both lines
# together. get_url verifies the checksum, so a mismatched pair fails the
# apply rather than installing an unverified binary.
sonarqube_scanner_version: "8.1.0.6389"
sonarqube_scanner_sha256: "bb8f709f9cb73352f8d1260a3b3c506c0f41146754bc630762c126d795499d0b"
sonarqube_scanner_root: /opt/sonar-scanner
```

- [ ] **Step 2: Add the scanner tasks to the role**

Append to `roles/sonarqube/tasks/main.yml`:

```yaml
# --- scanner -----------------------------------------------------------------
- name: Download the CLI scanner
  ansible.builtin.get_url:
    url: >-
      https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-{{ sonarqube_scanner_version }}-linux-x64.zip
    dest: /opt/sonar-scanner-cli-{{ sonarqube_scanner_version }}.zip
    checksum: "sha256:{{ sonarqube_scanner_sha256 }}"
    owner: root
    group: root
    mode: "0644"

- name: Unpack the CLI scanner
  ansible.builtin.unarchive:
    src: /opt/sonar-scanner-cli-{{ sonarqube_scanner_version }}.zip
    dest: /opt
    remote_src: true
    owner: root
    group: root
    creates: /opt/sonar-scanner-{{ sonarqube_scanner_version }}-linux-x64

- name: Link the scanner to a stable path
  ansible.builtin.file:
    src: /opt/sonar-scanner-{{ sonarqube_scanner_version }}-linux-x64
    dest: "{{ sonarqube_scanner_root }}"
    state: link

- name: Put the scanner on PATH
  ansible.builtin.file:
    src: "{{ sonarqube_scanner_root }}/bin/sonar-scanner"
    dest: /usr/local/bin/sonar-scanner
    state: link
```

- [ ] **Step 3: Write the smoke test**

`scripts/smoke_sonarqube.sh`:

```bash
#!/usr/bin/env bash
# End-to-end check that the FORK's reason for existing actually works:
# long-lived branch analysis on SonarQube Community Build.
#
# Deliberately NOT part of verify.yml. It creates a project, submits two
# analyses and deletes the project, so it mutates server state and needs an
# admin token -- neither of which belongs in a check that runs automatically
# after every apply.
#
# Generate a token in the UI (My Account -> Security -> Generate Token, type
# "User Token"), then run on lab:
#
#   SONAR_TOKEN=squ_xxx ./scripts/smoke_sonarqube.sh
#
# Exits 0 only if BOTH branches come back from api/project_branches/list.
set -euo pipefail

: "${SONAR_TOKEN:?set SONAR_TOKEN to a user token with project-admin rights}"
HOST=${SONAR_HOST_URL:-http://127.0.0.1:9000}
PROJECT=${SONAR_SMOKE_PROJECT:-smoke-branch-check}
BRANCH=${SONAR_SMOKE_BRANCH:-smoke-feature}

SCANNER=${SONAR_SCANNER:-/usr/local/bin/sonar-scanner}
[ -x "$SCANNER" ] || { echo "no scanner at $SCANNER" >&2; exit 1; }

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

api() {
  local method=$1 path=$2; shift 2
  curl -sS -u "$SONAR_TOKEN:" -X "$method" "$HOST/api/$path" "$@"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sonar-smoke.XXXXXX")
cleanup() {
  log "deleting project $PROJECT"
  api POST "projects/delete" -d "project=$PROJECT" >/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# A fixture with a real, obvious finding, so a scan that produces zero issues
# is itself a signal that analysis did not run.
mkdir -p "$WORK/src"
cat > "$WORK/src/Smoke.java" <<'JAVA'
public class Smoke {
  public static void main(String[] args) {
    String s = null;
    if (s.length() > 0) {        // NullPointerException, guaranteed finding
      System.out.println("unreachable");
    }
  }
}
JAVA

log "creating project $PROJECT"
api POST "projects/create" -d "project=$PROJECT" -d "name=$PROJECT" >/dev/null

scan() {
  local extra=("$@")
  (cd "$WORK" && "$SCANNER" \
    -Dsonar.host.url="$HOST" \
    -Dsonar.token="$SONAR_TOKEN" \
    -Dsonar.projectKey="$PROJECT" \
    -Dsonar.sources=src \
    -Dsonar.java.binaries=. \
    -Dsonar.scm.disabled=true \
    "${extra[@]}" >"$WORK/scan.log" 2>&1) || {
      echo "--- scanner output ---" >&2
      tail -40 "$WORK/scan.log" >&2
      return 1
    }
}

# The main branch must be analyzed once before any other branch, which the
# fork's docs/community-branch-analysis.md states explicitly: a new branch uses
# the main branch as its reference.
log "scanning the main branch"
scan

log "waiting for the compute engine to finish"
for _ in $(seq 60); do
  pending=$(api GET "ce/activity_status?component=$PROJECT" \
    | sed -n 's/.*"pending": *\([0-9]*\).*/\1/p')
  inprog=$(api GET "ce/activity_status?component=$PROJECT" \
    | sed -n 's/.*"inProgress": *\([0-9]*\).*/\1/p')
  [ "${pending:-1}" = "0" ] && [ "${inprog:-1}" = "0" ] && break
  sleep 2
done

log "scanning branch $BRANCH"
scan -Dsonar.branch.name="$BRANCH"

log "waiting for the compute engine again"
for _ in $(seq 60); do
  pending=$(api GET "ce/activity_status?component=$PROJECT" \
    | sed -n 's/.*"pending": *\([0-9]*\).*/\1/p')
  [ "${pending:-1}" = "0" ] && break
  sleep 2
done

BRANCHES=$(api GET "project_branches/list?project=$PROJECT")
log "branches: $BRANCHES"

# The actual assertion. Community Build without the fork's plugin accepts the
# scan and silently records everything on the main branch, so checking that
# the SCAN succeeded proves nothing -- only the branch list does.
echo "$BRANCHES" | grep -q "\"name\":\"$BRANCH\"" || {
  echo "FAIL: branch $BRANCH is not in the branch list -- branch analysis did not work" >&2
  exit 1
}

log "PASS: $BRANCH was recorded as its own branch"
```

- [ ] **Step 4: Apply the role, then run the smoke test**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube
scp scripts/smoke_sonarqube.sh lab:/tmp/
```

Generate a token in the UI at `http://lab.local:9000` (My Account → Security),
then:

```bash
ssh lab 'SONAR_TOKEN=squ_xxx bash /tmp/smoke_sonarqube.sh'
```

Expected: `PASS: smoke-feature was recorded as its own branch`.

A failure here with a successful scan is the interesting case and means the
branch plugin is not active even though its jar is present. Check
`journalctl -u sonarqube | grep -i branch` and the `web.log` under
`/var/log/sonarqube` before changing anything.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke_sonarqube.sh hosts/lab/vars.yml roles/sonarqube/tasks/main.yml
git commit -m "feat(sonarqube): pin the CLI scanner and add a branch-analysis smoke test"
```

---

### Task 8: Measure the idle cost, and write the runbook

The spec commits to measuring whether an always-on SonarQube can stop the box
powering off. Review Focus 5. This task closes it with a number, not a
prediction.

**Files:**
- Modify: `docs/RUNBOOK.md`
- Modify: `hosts/lab/vars.yml` (only if the measurement demands it)

**Interfaces:**
- Consumes: a running SonarQube; `power_idle_cpu_max`, `power_idle_load_max`,
  `power_idle_window_minutes` from `vars.yml`.
- Produces: a recorded measurement in `docs/RUNBOOK.md`.

- [ ] **Step 1: Let it idle, then read what the idle check actually reads**

The idle check reads `sar`, not `top`, so measure the same source it does.
Leave SonarQube running and untouched for at least the full idle window
(`power_idle_window_minutes: 60`), then:

```bash
ssh lab 'uptime; echo "--- sar CPU, last hour ---"; sar -u -s $(date -d "60 min ago" +%H:%M:%S) | tail -10; echo "--- sar load ---"; sar -q -s $(date -d "60 min ago" +%H:%M:%S) | tail -10'
```

Record `%user + %system` and `ldavg-5`. The thresholds are 5.0% CPU and 0.50
load.

- [ ] **Step 2: Dry-run the real idle check and read its verdict**

Do not infer the outcome from the numbers -- run the script the timer runs and
read what it decides:

```bash
ssh lab 'sudo /usr/local/sbin/lab-idle-shutdown --dry-run 2>&1 | tail -30'
```

If that is not the flag the installed script uses, read the top of
`/usr/local/sbin/lab-idle-shutdown` for the dry-run invocation rather than
guessing. Expected: every signal clear, including CPU and load, and the only
thing holding it back being the shutdown window or `power_min_uptime_minutes`.

- [ ] **Step 3: If and only if SonarQube trips a threshold, exclude it by identity**

Do **not** raise `power_idle_cpu_max`: that would blunt the signal for every
other workload on the box. The established mechanism is exclusion by unit
identity -- `power_gpu_exclude_unit` does exactly this for bobgpt's CUDA
context. If the measurement shows SonarQube is the cause, add an equivalent
CPU-side exclusion and record the measured numbers in the variable's comment,
the way the `gpu_power_limits` entries do.

If it does not trip, change nothing. A variable added "just in case" is a
variable nobody can later tell was needed.

- [ ] **Step 4: Write the runbook section**

Append to `docs/RUNBOOK.md`, matching the file's existing heading style:

```markdown
## SonarQube

Robert's fork of SonarQube Community Build
(`github.com/bobcowher/sonarqube`), built from source on this host. It adds
long-lived branch analysis, bundled as a plugin rather than installed as one.
Design: `docs/superpowers/specs/2026-10-12-sonarqube-deployment-design.md`.

- **URL:** `http://lab.local:9000`, or `http://lab.local/sonar` which redirects
  there. Same URL for the browser and for `sonar.host.url`.
- **Deploy or update:** `ssh lab sonarqube-deploy`. It resets
  `/opt/sonarqube/src` to `origin/master`, builds the zip, unpacks it to
  `/opt/sonarqube/releases/<version>-<sha>`, flips `/opt/sonarqube/current`,
  restarts, and **rolls the symlink back if the new release does not reach
  `UP`**. 20-45 minutes on a cold Gradle cache.
- **Which release is live:** `readlink /opt/sonarqube/current`, cross-checked
  against `curl -s localhost:9000/api/server/version`. `verify.yml` asserts
  these agree, because a flipped symlink with a stale process serving looks
  healthy in every other way.
- **Roll back by hand:** point `current` at an older release directory and
  restart. `sonarqube-deploy` keeps three.
- **Logs:** `/var/log/sonarqube/{sonar,web,ce,es}.log`. The journal
  (`journalctl -u sonarqube`) carries only the launcher's output; the useful
  detail is in those four files.
- **Configuration:** `/etc/sonarqube/sonarqube.env`, read by the unit as an
  `EnvironmentFile`. `SONAR_JDBC_URL` style keys map from `sonar.jdbc.url` by
  uppercasing and replacing `.` and `-` with `_`. Nothing is configured inside
  a release directory, which is what makes the symlink swap atomic.

### Never install a plugin through the web UI

There is no `sonar.path.extensions`: a Marketplace plugin lands inside the
release directory and the next deploy destroys it. Anything needed must be
bundled in the fork, where a git SHA describes it. This is also what keeps
"clone the Ansible repo and get this host back" true.

### A dirty Elasticsearch index after a hard poweroff

This box powers off nightly, and an unclean Elasticsearch shutdown can leave
the index inconsistent -- the symptom is SonarQube starting but projects or
issues being missing or unsearchable. The index is **derived state**, rebuilt
from PostgreSQL:

    sudo systemctl stop sonarqube
    sudo rm -rf /data/sonarqube/data/es*
    sudo systemctl start sonarqube

Reindexing takes a few minutes and loses nothing.

### What a rebuild does not restore

`ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml --tags sonarqube`
against a bare host restores the toolchain, the database, the checkout, a
build, the service, the firewall rule and the route -- one command, because the
role runs `sonarqube-deploy` when `/opt/sonarqube/current` is absent.

It does **not** restore the contents of PostgreSQL: projects, issues, analysis
history, quality gates, users and tokens. No backup is taken, by Robert's
decision on 2026-10-12. A rebuild gives a clean working server with no past
analyses. If that ever stings, a nightly `pg_dump` at ~23:30 is the fix -- not
midnight, because the power role's shutdown window opens at 00:00 and the job
would race the poweroff.

### Idle cost

Measured <DATE>: `sar` CPU `<value>%`, `ldavg-5` `<value>`, against thresholds
of 5.0% and 0.50. <Either: "Comfortably clear, so SonarQube has no exclusion in
the power role and gets no veto signal -- an idle SonarQube means nobody is
using it." Or: a description of the exclusion that was needed and why.>
```

Replace the `<DATE>` and `<value>` placeholders with the numbers from Step 1,
and pick the sentence that matches what Step 2 actually decided. **Do not leave
them as placeholders, and do not write a number you did not measure.**

- [ ] **Step 5: Run the full verification one more time, from scratch**

```bash
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml
```

The whole play, not just the sonarqube tag: this proves the new role does not
break anything else, and that a second apply is idempotent. Expected: the
sonarqube tasks report `changed=0` (the first-build task is skipped because
`current` exists), and every assertion in `verify.yml` passes.

- [ ] **Step 6: Run the deploy script's unit tests once more and commit**

```bash
./scripts/test_sonarqube_deploy.sh
git add docs/RUNBOOK.md hosts/lab/vars.yml
git commit -m "docs: SonarQube operations, recovery limits, and measured idle cost"
```

---

## Done when

- `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml` is idempotent
  and every `verify.yml` assertion passes.
- `./scripts/test_sonarqube_deploy.sh` reports `18 passed, 0 failed`.
- `scripts/smoke_sonarqube.sh` records a second branch, proving the fork's
  feature works on the deployed instance.
- `http://lab.local:9000` and `http://lab.local/sonar` both reach the UI from
  the desktop.
- `grep -rn "26\.11" roles/sonarqube hosts/lab/` finds nothing: no SonarQube
  version lives in this repository.
- `docs/RUNBOOK.md` records a measured idle cost, not a predicted one.
