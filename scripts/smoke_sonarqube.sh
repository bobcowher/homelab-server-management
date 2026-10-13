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

# inProgress as well as pending, same as the loop above. Waiting only on
# pending let this pass while the branch's analysis was still being processed:
# the branch appeared in the list with an empty status object, because
# project_branches/list shows a branch as soon as the scanner has registered
# it. Asserting on a branch that exists but has not been analyzed would be a
# green that proves nothing.
log "waiting for the compute engine again"
for _ in $(seq 60); do
  st=$(api GET "ce/activity_status?component=$PROJECT")
  pending=$(echo "$st" | sed -n 's/.*"pending": *\([0-9]*\).*/\1/p')
  inprog=$(echo "$st" | sed -n 's/.*"inProgress": *\([0-9]*\).*/\1/p')
  [ "${pending:-1}" = "0" ] && [ "${inprog:-1}" = "0" ] && break
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

# Existence is not analysis. project_branches/list shows a branch as soon as
# the scanner registers it, with an empty status object, so the check above
# can pass while the compute engine is still working -- which is exactly what
# happened on the first run of this script. Asking for a MEASURE on that
# branch is the narrow question: a measure only exists once the branch has
# been analyzed in its own right.
log "checking $BRANCH has its own analyzed measures"
NCLOC=$(api GET "measures/component?component=$PROJECT&branch=$BRANCH&metricKeys=ncloc")
echo "$NCLOC" | grep -q '"value":"[1-9]' || {
  echo "FAIL: branch $BRANCH has no ncloc measure -- it was registered, not analyzed" >&2
  echo "$NCLOC" >&2
  exit 1
}

log "PASS: $BRANCH was recorded as its own branch"
