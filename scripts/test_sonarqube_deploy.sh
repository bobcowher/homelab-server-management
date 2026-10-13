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
# Modelled on scripts/test_idle_checks.sh. Run from anywhere:
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

# Writes a zip shaped exactly like the one :sonar-application:zip produces,
# which is NOT the obvious shape: the ARCHIVE is sonar-application-<version>.zip
# while the single directory INSIDE it is sonarqube-<version>/. The first real
# build on lab (2026-10-13) failed on precisely this -- the script globbed for
# sonarqube-*.zip, found nothing, and refused to deploy. Observed artifact:
# sonar-application-26.11-SNAPSHOT.zip containing sonarqube-26.11-SNAPSHOT/.
make_zip() {
  local root=$1 version=$2
  local stage
  stage=$(mktemp -d "${TMPDIR:-/tmp}/sqzip.XXXXXX")
  mkdir -p "$stage/sonarqube-$version/lib"
  : > "$stage/sonarqube-$version/lib/sonar-application-$version.jar"
  (cd "$stage" && zip -qr \
    "$root/src/sonar-application/build/distributions/sonar-application-$version.zip" \
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
  # Not cosmetic. PluginDownloader.start() calls forceMkdir on
  # <home>/extensions/downloads and throws IllegalStateException if it cannot
  # create it, and under ProtectSystem=strict the release tree is read-only at
  # runtime -- so the web server died on startup until the deploy created this
  # directory while the tree was still writable (lab, 2026-10-13). forceMkdir
  # is a no-op when the directory already exists, which is what makes
  # pre-creating it sufficient.
  check "happy: extensions/downloads pre-created" "yes" \
    "$([ -d "$root/releases/26.11-deadbee/extensions/downloads" ] && echo yes || echo no)"
  rm -rf "$root"
}

# Review Focus 2. A release that builds but will not start must leave the
# PREVIOUS release serving. A deploy that takes the box down is worse than one
# that refuses to deploy.
test_rollback() {
  local root out rc
  root=$(make_world)

  make_zip "$root" "26.11"
  echo '{"status":"UP"}' > "$root/status.txt"
  run_deploy "$root" > /dev/null

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
# that cannot run -- a dangling current would become the next deploy's
# rollback target, quietly making the next failure unrecoverable too.
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

  for v in 90.1 90.2 90.3 90.4; do
    mkdir -p "$root/releases/$v-aaaaaaa"
    touch "$root/releases/$v-aaaaaaa"
  done
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
