# Deploying the SonarQube fork on lab

Status: approved design, not yet implemented
Date: 2026-10-12

## Goal

Run Robert's SonarQube fork on lab, built from source, and make **this**
repository the recovery path for it. Clone this repo, run the play against a
bare lab, and SonarQube comes back: the JDK, the database, the checkout, a
build, the service, the firewall rule, the route.

Stated by Robert on 2026-10-12: *"It leaves us in a spot where I can pull this
repo and bring everything back, which is my goal."*

Success is concrete: the web UI is up, a project can be created, a scan lands,
and `sonar.branch.name` works -- the feature the fork exists for.

Non-goals: pull-request analysis (the fork deliberately rejects
`sonar.pullrequest.*`), CI integration, reachability beyond the LAN,
multi-user tuning, and performance work of any kind.

## Ownership

Unlike `bobgptv1`, this fork is Robert's alone, so there is no hard boundary
against touching it. The boundary here is **practical, not political**: the
fork is rebased onto `upstream/master` periodically, and every file this
repository adds to it is another conflict surface at rebase time. So the
deployment machinery lives here and the fork stays as close to upstream plus
one feature commit as it can.

The fork's side of the contract is exactly what its own README already
promises:

```shell
./gradlew :sonar-application:zip     # -> sonar-application/build/distributions/
```

That zip is the unit of deployment. Nothing else is asked of the fork.

## What already exists

The fork (`github.com/bobcowher/sonarqube`, local `~/javaprojects/sonarqube`):

- SonarQube Community Build 26.11, `master` level with `origin/master`.
- One feature commit, `22b9e9e965a` "Add community branch analysis support":
  26 files, a new `plugins/sonar-community-branch-plugin` module wired in at
  `settings.gradle:31` and bundled at `sonar-application/bundled_plugins.gradle`
  via `bundledPlugin project(':plugins:sonar-community-branch-plugin')`.
  Because it is bundled, the distribution carries it -- no separate plugin
  install and no Java agent, which the fork's docs state explicitly.
- `gradle.properties` names `jre_release_name=jdk-21.0.12.1+1`.
- **No Dockerfile anywhere in the tree.** Upstream builds its images in a
  separate repository, so containerising would mean writing and maintaining
  our own Dockerfile against a moving fork. That is the main reason this
  design runs SonarQube natively.

Lab, probed 2026-10-12 22:20 (not recalled -- measured):

- Up 6h, load 0.02. 1.5 TB free on `/`. 88 GB RAM available of 92.
- `node` and `npm` present at `/usr/bin`.
- **No JDK.** `openjdk-21-jdk` is in apt at `21.0.12.1+1-1~26.04.4` --
  the same build the fork names in `gradle.properties`.
- **No PostgreSQL.** Ubuntu 26.04 offers `postgresql-18` only (18.6).
- `vm.max_map_count` is already 1048576, well above the 524288 bundled
  Elasticsearch requires. Nothing to change, but the role asserts it rather
  than assuming it stays true.
- `webstack` runs six containers behind Caddy on :80.

## Decisions

### Build on lab, deploy by release symlink

Lab is a 5950X with 88 GB free and 1.5 TB of disk -- the best build machine in
the house -- and already has `node`/`npm`. Building there keeps the entire
loop on one host: `ssh lab sonarqube-deploy` and nothing else moves.

The alternatives were weighed and rejected:

- *Build on the desktop, ship the zip.* Couples every deploy to one
  workstation, makes this repository reference a path in `~/javaprojects`, and
  pushes a large artifact over the LAN per iteration.
- *GitHub Releases.* Genuinely versioned and the cleanest separation, but a
  release per experiment is friction during active development of the fork.

The deploy is a **release symlink flip**, not an in-place upgrade:
`/opt/sonarqube/releases/<version>-<shortsha>/` holds unpacked zips and
`/opt/sonarqube/current` points at the live one. This matters for three
reasons: the build completes before anything is swapped, so a broken commit
cannot take down a running server; rollback is a symlink; and the running
release is identified by a git SHA, which is what makes "bring everything
back" auditable.

### Configuration by environment, not by a file inside the release

Verified in the fork's source rather than assumed:
`AppSettingsLoaderImpl.load()` reads `conf/sonar.properties`, then overrides
every known key from the environment, then applies CLI arguments. The mapping
is `SettingFormatter.fromJavaPropertyToEnvVariable` (`SettingFormatter.java:32`):
uppercase, `.` and `-` both to `_`. So `sonar.jdbc.url` is `SONAR_JDBC_URL`.

Consequence: **no configuration needs to be written into the release
directory.** Everything lives in one `EnvironmentFile`, outside the tree that
gets replaced. Without this, every deploy would have to re-template a config
file into the new release and the symlink flip would stop being atomic in any
meaningful sense.

`sonar.path.home` is the one key that cannot be set this way --
`AppSettingsLoaderImpl:124` forces it to the detected jar location *after* the
environment pass. That is the desired behaviour: home is the release.

### All mutable state lives outside the release tree

`ProcessProperties.java:69-73` defines `sonar.path.data` (default `data`),
`.logs`, `.temp` and `.web`, and `FileSystemSettings` honours absolute paths,
resolving relative ones against home. Pointing data, temp and logs at absolute
paths outside `/opt/sonarqube/releases` means swapping releases touches no
state at all.

**There is no `sonar.path.extensions`.** Plugins installed through the
Marketplace UI land under the release directory and will not survive a
redeploy. This is recorded as a rule, not a footnote: **never install a plugin
through the web UI on this host.** Anything needed must be bundled in the fork,
where a git SHA describes it. That restriction is what keeps the recovery claim
honest.

### Native PostgreSQL 18 from apt

SonarQube Community Build has no embedded database; a real PostgreSQL is
mandatory. The fork's own shipped
`sonar-application/src/main/assembly/conf/sonar.properties:41` says
*"PostgreSQL 14 or greater"* with no upper bound, and `build.gradle:638` pins
JDBC driver `org.postgresql:postgresql:42.7.13`, which speaks the PG 18
protocol. Ubuntu 26.04's `postgresql-18` therefore qualifies.

Honesty about the evidence: the dialect's own version check lives in an
external `sonar-db-core` artifact that is not in this tree, so the above is the
distribution's documentation plus the driver version, not a source read of the
check itself. **If PG 18 is refused at startup, say so plainly and fall back to
a pinned `postgres:17` container** -- do not quietly work around it.

Native rather than containerised because SonarQube is the only consumer, it
removes a docker-ordering dependency from the boot path, and it keeps the
database password out of a compose file in a public repository.

### Enabled at boot, and it never vetoes the overnight shutdown

Robert's choice: always on, so it is simply there each morning rather than
costing 60-90 seconds of Elasticsearch startup every time he wants to scan.

SonarQube gets **no** signal in the power role. It must never hold the box
awake -- unlike bobgpt, an idle SonarQube means nobody is using it, not that
someone is mid-conversation.

The risk this creates is the reverse one: three idle JVMs could raise `sar` CPU
above `power_idle_cpu_max` (5.0%) or load above `power_idle_load_max` (0.50)
and block every shutdown by accident. The expectation is well under 1%, but
**that is a prediction and must be measured on the running service and
reported** before this is called done. If it does trip the threshold, the fix
is a cgroup exclusion by unit identity -- the mechanism `power_gpu_exclude_unit`
already establishes -- not a raised threshold.

### Port 9000 on the LAN, with a Caddy redirect for convenience

Binds `0.0.0.0:9000`; ufw allows 9000 from `lan_subnet` only. No
`docker_bridge_subnet` rule: unlike bobgpt and llama-swap, nothing in a
container talks to SonarQube, so that rule would be real surface for no gain.

Caddy gets `redir /sonar -> http://lab.local:9000/`, the pattern already used
for beekeeper, rather than a reverse proxy. Proxying under a subpath would
require setting `sonar.web.context=/sonar`, which makes the browser URL and the
scanner URL different strings. One URL is worth more than one fewer port.

### Nothing scheduled

Robert's explicit decision on 2026-10-12, after being told that SonarQube needs
no scheduled data update of its own: it purges its own database after each
analysis, and the Elasticsearch index is derived from PostgreSQL.

A nightly `pg_dump` was offered and declined. The consequence is recorded under
*Recovery* below so it reads as a decision rather than an oversight.

Note for anything scheduled in future: the power role's shutdown window is
`00..08` and the 00:00 check is usually the one that fires, so a midnight job
races the poweroff. Nightly work belongs at ~23:30.

## Filesystem layout

```
/opt/sonarqube/src/                       git checkout, robertcowher:ml
/opt/sonarqube/releases/26.11-22b9e9e9/   unpacked zip, sonarqube-owned
/opt/sonarqube/current -> releases/...    the live release
/etc/sonarqube/sonarqube.env              service env, 0640 root:sonarqube
/etc/sonarqube/deploy.env                 deploy env, 0644, no secrets
/etc/sonarqube/db_password                generated once, 0600 root
/data/sonarqube/data                      SONAR_PATH_DATA  (ES indices)
/data/sonarqube/temp                      SONAR_PATH_TEMP
/var/log/sonarqube                        SONAR_PATH_LOGS
```

`src` is owned by `robertcowher:ml` so builds need no sudo -- the same reason
`/opt/bobgpt` is owned that way. Ansible clones it **once** with `update:
false` and never touches it again, so a playbook run can never revert what a
deploy checked out. The service account `sonarqube` is a system user with
`nologin`; bundled Elasticsearch refuses to run as root.

## The deploy script

`/usr/local/bin/sonarqube-deploy`, installed by the role, run as `robertcowher`
(who has passwordless sudo on this host; the script uses it only for the
unpack, the symlink and the restart):

1. `git fetch && git reset --hard origin/$SONARQUBE_BRANCH` in `src`. A reset
   rather than a pull because this is a deploy checkout, not a work tree.
2. Remove `sonar-application/build/distributions` and run
   `./gradlew :sonar-application:zip`.
3. Glob the result. **Abort if the glob matches zero or more than one file** --
   never pick one. A stale zip silently deployed is the failure this guards.
4. Unpack to `releases/<version>-<shortsha>`, where the version comes from the
   zip's own directory name and the SHA from git. Chown to `sonarqube`.
5. Flip `current` atomically and `systemctl restart sonarqube`.
6. Poll `/api/system/status` until `UP` or a timeout. **On timeout, flip the
   symlink back to the previous release and restart.**
7. Prune to the last three releases.

Step 6 is the point of the whole structure. A commit that builds but will not
start costs a few minutes, not a working server.

No version string appears anywhere in this repository: the version comes from
the zip, the SHA from git, and the application jar from a glob inside a small
`sonarqube-run` wrapper, because systemd's `ExecStart` cannot glob.

## Configuration contract

Two environment files, deliberately separate. Mixing them would load deploy
settings into SonarQube's property namespace, where `AppSettingsLoaderImpl`
warns about every key it does not recognise.

`/etc/sonarqube/sonarqube.env` -- read by the service, `0640 root:sonarqube`
because it carries the database password. Every key here is a real
`ProcessProperties` key run through the uppercase/underscore mapping, so each
one is checkable against the source rather than folklore:

```
SONAR_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/sonarqube
SONAR_JDBC_USERNAME=sonarqube
SONAR_JDBC_PASSWORD=<generated on the host, never in git>
SONAR_PATH_DATA=/data/sonarqube/data
SONAR_PATH_TEMP=/data/sonarqube/temp
SONAR_PATH_LOGS=/var/log/sonarqube
SONAR_WEB_HOST=0.0.0.0
SONAR_WEB_PORT=9000
SONAR_TELEMETRY_ENABLE=false
```

`SONAR_TELEMETRY_ENABLE=false` is set for the same reason the fork's own
`start.sh` disables it on dev instances: this is a private box and should not
report to anyone's analytics.

`/etc/sonarqube/deploy.env` -- read by `sonarqube-deploy` only, `0644`, no
secrets:

```
SONARQUBE_BRANCH=master
SONARQUBE_KEEP_RELEASES=3
SONARQUBE_START_TIMEOUT=300
```

`SONARQUBE_BRANCH` is bootstrap-and-deploy policy, not a pin: Ansible clones it
once, the deploy script resets to it, and changing it here changes what the
next deploy builds.

The password is generated on the host with `openssl rand`, guarded by
`creates:`, read back with `slurp`, and used both to set the PostgreSQL role
password and to render this file -- exactly the pattern
`roles/webstack/tasks/main.yml` already uses for the SearXNG secret key. This
repository is public; nothing generated may land in git.

## The systemd unit

`Type=simple`, `User=sonarqube`, `After=network-online.target
postgresql.service`, `Restart=on-failure`.

`ExecStart` calls `/usr/local/bin/sonarqube-run`, a three-line wrapper that
globs `/opt/sonarqube/current/lib/sonar-application-*.jar` and `exec`s
`java -jar` on it. The glob is the reason the wrapper exists -- the jar name
carries the version and `ExecStart` does not glob.

Two limits are load-bearing rather than cosmetic, because bundled
Elasticsearch runs bootstrap checks against them at startup and refuses to
start if they are too low:

```
LimitNOFILE=131072
LimitNPROC=8192
```

`vm.max_map_count` is the third such check. Lab already reports 1048576,
comfortably above the 524288 Elasticsearch wants, but the role sets it
explicitly through `sysctl` with a dropped-in file rather than relying on a
value that happens to be true today.

Hardening starts strict -- `ProtectSystem=strict`, `NoNewPrivileges=yes`,
`PrivateTmp=no` (temp is relocated to `/data/sonarqube/temp`, so a private
`/tmp` would only hide it) -- with `ReadWritePaths` naming the data, temp and
log directories and nothing else. The bobgpt unit demonstrates this works for a
service of this shape. If Elasticsearch needs more, loosen it **against an
observed failure** and record in the role what forced the change.

## Verification

In `hosts/lab/verify.yml`, which runs automatically after every apply:

- `sonarqube` and `postgresql` are both **enabled and active**.
- `GET /api/system/status` returns `UP`. Liveness, not "a process exists".
- `GET /api/server/version` **equals the version in the `current` symlink
  target.** This catches the genuinely nasty state: symlink flipped, JVM still
  serving the previous release.
- The community branch plugin jar is present in the live release.
- ufw allows 9000 from `lan_subnet`.

`scripts/smoke_sonarqube.sh` is deliberately **not** in `verify.yml`: it
mutates state and needs a token. It creates a throwaway project, scans a
fixture on the main branch, scans again with `-Dsonar.branch.name=`, asserts
both branches come back from `api/project_branches/list`, and deletes the
project. It is the only check that exercises the reason the fork exists, so it
is run by hand after a deploy that touches the branch code.

`sonar-scanner-cli` is installed on lab with its version and sha256 pinned in
`vars.yml`, following the `llama_swap_version` / `llama_swap_sha256` precedent.
It exists for the smoke test; that it also allows scanning from lab directly is
a side benefit.

## Recovery: what comes back, and what does not

**Comes back** from `ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml
-t sonarqube` against a bare host: JDK 21, PostgreSQL and its role and
database, a freshly generated password, the fork cloned, **built** (the role
runs `sonarqube-deploy` once when `/opt/sonarqube/current` is absent, which is
what makes this one command rather than two), the service enabled and started,
the firewall rule, and the Caddy route.

**Does not come back:** everything in PostgreSQL -- projects, issues, analysis
history, quality gates, users and tokens. No backup is taken, by decision. A
rebuild yields a clean, working server with no past analyses. A one-line
`pg_dump` before the nightly poweroff is the cheap fix if that ever stings.

## Known limitations

- Marketplace-installed plugins do not survive a redeploy (no
  `sonar.path.extensions`). Bundle in the fork instead.
- A hard overnight poweroff can leave the Elasticsearch index dirty. It is
  derived state: deleting `/data/sonarqube/data/es*` and restarting rebuilds it
  from PostgreSQL. To be recorded in `docs/RUNBOOK.md`.
- First build will be slow and will populate a multi-GB Gradle cache under
  `~robertcowher/.gradle` on lab.

## Open questions

- Does `postgresql-18` satisfy SonarQube 26.11's dialect check? Evidence says
  yes; it is confirmed only at first startup.
- Does the Gradle build need a specific Node version that lab's system `node`
  does not satisfy? The web build may fetch its own; discovered at first build.
- Does idle SonarQube stay under the power role's thresholds? Must be measured.
- How much does `ProtectSystem=strict` need relaxing for three JVMs plus
  Elasticsearch? Start strict with explicit `ReadWritePaths`, loosen only
  against an observed failure, and record what forced it.

## Out of scope

Pull-request analysis and decoration, CI or beekeeper integration, external
reachability, HTTPS, backups, upgrading across SonarQube major versions, and
any tuning of analysis itself.
