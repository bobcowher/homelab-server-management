#!/usr/bin/env bash
# Exercise the veto branches of lab-idle-shutdown that normal conditions never
# reach. Run ON LAB. Read-only: every case runs a modified COPY under --dry-run,
# so nothing can power the box off.
#
#   sudo scripts/test_idle_checks.sh
#
# Exists because the branches that matter most are the ones an idle box never
# takes. In particular the cross-midnight sar path: every hand-run of this
# script happens in the evening, inside a single saDD file, while the timer
# fires at 00:00 when the trailing hour lives in YESTERDAY's file -- a different
# code path that would otherwise reach production having never once run.
set -uo pipefail

REAL=/usr/local/sbin/lab-idle-shutdown
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# $1 label, $2 expected text in output, $3.. sed expressions applied to the copy
check() {
    local label="$1" expect="$2"; shift 2
    local copy="$WORK/case.sh"
    cp "$REAL" "$copy"
    for expr in "$@"; do sed -i "$expr" "$copy"; done
    chmod +x "$copy"

    local out
    out=$("$copy" --dry-run 2>&1)
    if grep -qF "$expect" <<<"$out"; then
        echo "PASS  $label"
        pass=$(( pass + 1 ))
    else
        echo "FAIL  $label"
        echo "      expected to find: $expect"
        sed 's/^/      | /' <<<"$out"
        fail=$(( fail + 1 ))
    fi
}

echo "== sar history =="

# 1400 minutes back forces start_day != now_day, which is exactly what happens
# at 00:00. Proves the two-file read works and does not fall through to NO DATA.
check "cross-midnight window still finds history" "peak ldavg-5" \
    's/^IDLE_MINUTES=.*/IDLE_MINUTES=1400/'

check "cross-midnight window is not NO DATA" "peak cpu%" \
    's/^IDLE_MINUTES=.*/IDLE_MINUTES=1400/'

# A directory with no saDD files at all: the collector is broken or /var/log was
# wiped. Must veto rather than read silence as idleness.
mkdir -p "$WORK/empty-sysstat"
check "missing sysstat history vetoes" "no sysstat history" \
    "s|^SYSSTAT_DIR=.*|SYSSTAT_DIR=\"$WORK/empty-sysstat\"|"

echo
echo "== thresholds =="

# Negative ceilings, so any reading at all exceeds them. A small positive value
# looks more realistic but is not: a genuinely quiet box reads 0.00, and
# 0.00 > 0.001 is false, so the veto never fires and the test passes or fails
# depending on ambient load rather than on the code.
check "load above threshold vetoes" "load peaked at" \
    's/^LOAD_MAX=.*/LOAD_MAX="-1"/'

check "cpu above threshold vetoes" "CPU peaked at" \
    's/^CPU_MAX=.*/CPU_MAX="-1"/'

echo
echo "== beekeeper =="

# The exact shape beekeeper returns while training. The busy branch has never
# run against the real service -- the one run during development crashed before
# reporting busy -- so this is its only coverage.
#
# Served over file:// rather than an HTTP stub. `python3 -m http.server`
# changed its CLI in 3.14 and now fails to start, which made this case
# silently exercise the "unreachable" branch instead. curl reads file:// with
# no server, no port, and nothing to wait for.
cat > "$WORK/busy.json" <<'JSON'
{"data":{"busy":true,"running_projects":["franka-kitchen-bc"],"setting_up_projects":[]},"success":true}
JSON

check "beekeeper busy vetoes, and names the project" "beekeeper is training: franka-kitchen-bc" \
    "s|^BEEKEEPER_URL=.*|BEEKEEPER_URL=\"file://$WORK/busy.json\"|"

check "beekeeper unreachable does not veto" "unreachable (not treated as active)" \
    's|^BEEKEEPER_URL=.*|BEEKEEPER_URL="http://127.0.0.1:1/nope"|'

echo
echo "== manual override =="

flag="$WORK/no-suspend-flag"
touch "$flag"
check "override flag vetoes" "manual override flag" \
    "s|^OVERRIDE_FLAG=.*|OVERRIDE_FLAG=\"$flag\"|"

rm -f "$flag"
check "absent override flag does not veto" "manual override          absent" \
    "s|^OVERRIDE_FLAG=.*|OVERRIDE_FLAG=\"$flag\"|"

echo
echo "== reboot marker regression =="

# sar emits "21:35:48     LINUX RESTART  (32 CPU)" after a boot. That line
# begins with a timestamp, so an $1-only filter accepted it as data: the rows
# read non-empty, the NO DATA guard never fired, and the maxima computed to
# 0.00 from a line with no measurements -- the script called a box it knew
# nothing about idle. Shipped 2026-09-07, caught by this file the same day.
#
# Runs the filter out of the INSTALLED script rather than a copy of the
# expression, so editing the script cannot leave this passing against a stale
# duplicate.
restart_prog=$(sed -n '/^sar_data()/,/^}/p' "$REAL" | sed -n "s/.*awk '\\(.*\\)'.*/\\1/p")
if [[ -z "$restart_prog" ]]; then
    echo "FAIL  could not extract sar_data filter from $REAL"
    fail=$(( fail + 1 ))
else
    rows=$(printf '%s\n' \
        'Linux 7.0.0-31-generic (lab) 	2026-09-07 	_x86_64_	(32 CPU)' \
        '' \
        '21:35:48     LINUX RESTART	(32 CPU)' \
        | awk "$restart_prog" | grep -c . )
    if [[ "$rows" == "0" ]]; then
        echo "PASS  LINUX RESTART marker is not counted as a data row"
        pass=$(( pass + 1 ))
    else
        echo "FAIL  LINUX RESTART marker parsed as $rows data row(s)"
        fail=$(( fail + 1 ))
    fi

    # And the filter must still accept a real row, or it would reject
    # everything and merely look correct.
    rows=$(printf '%s\n' '21:41:21        all      0.48      0.00      0.24      0.01      0.00     99.27' \
        | awk "$restart_prog" | grep -c . )
    if [[ "$rows" == "1" ]]; then
        echo "PASS  a real sar row still passes the filter"
        pass=$(( pass + 1 ))
    else
        echo "FAIL  filter rejected a valid sar row"
        fail=$(( fail + 1 ))
    fi
fi

echo
echo "== session state filter =="

# The overnight run of 2026-09-07 fired all nine times and was vetoed all nine
# times by one session in State=closing -- a logind session whose leader had
# exited but whose cgroup still held a leaked process. Nobody was logged in.
# Counting those means a single stray background process pins the box awake
# forever, which is exactly what happened.
#
# Extracted from the INSTALLED script so this cannot pass against a stale copy.
sess_prog=$(sed -n '/^sessions_from_states()/,/^}/p' "$REAL" | sed -n "s/.*awk '\\(.*\\)'.*/\\1/p")
if [[ -z "$sess_prog" ]]; then
    echo "FAIL  could not extract sessions_from_states filter from $REAL"
    fail=$(( fail + 1 ))
else
    # label, expected count, fixture lines
    sess_case() {
        local label="$1" want="$2"; shift 2
        local got
        got=$(printf '%s\n' "$@" | awk "$sess_prog" | grep -c .)
        if [[ "$got" == "$want" ]]; then
            echo "PASS  $label"
            pass=$(( pass + 1 ))
        else
            echo "FAIL  $label -- expected $want, got $got"
            fail=$(( fail + 1 ))
        fi
    }

    sess_case "closing session is not counted" 0 "user closing"
    sess_case "active session is counted" 1 "user active"
    sess_case "online session is counted" 1 "user online"
    sess_case "manager session is never counted" 0 "manager active"
    sess_case "the exact overnight state counts nobody" 0 \
        "manager active" "user closing"
    sess_case "a real login alongside a corpse still counts" 1 \
        "manager active" "user closing" "user active"
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
