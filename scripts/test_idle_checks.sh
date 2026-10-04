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

# Inverse of check(): the text must NOT appear. Needed because some properties
# are only expressible negatively -- "this signal did not veto" is not the same
# claim as "nothing vetoed", and conflating them makes a test depend on whatever
# else happens to be running on the box.
check_absent() {
    local label="$1" forbidden="$2"; shift 2
    local copy="$WORK/case.sh"
    cp "$REAL" "$copy"
    for expr in "$@"; do sed -i "$expr" "$copy"; done
    chmod +x "$copy"

    local out
    out=$("$copy" --dry-run 2>&1)
    if grep -qF "$forbidden" <<<"$out"; then
        echo "FAIL  $label"
        echo "      expected NOT to find: $forbidden"
        sed 's/^/      | /' <<<"$out"
        fail=$(( fail + 1 ))
    else
        echo "PASS  $label"
        pass=$(( pass + 1 ))
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
echo "== minimum uptime =="

# 2026-10-03: booted 07:35:50, powered off at 08:00:06 -- 25 minutes after
# someone pressed the button to use the machine. The sar window cannot see
# across a boot, so the 50 minutes the box spent powered off read exactly like
# 50 quiet minutes, and the NO DATA guard did not fire because two real samples
# had already landed. An absurd minimum proves the veto branch exists at all.
check "uptime under the minimum vetoes" "under the" \
    's/^MIN_UPTIME_MINUTES=.*/MIN_UPTIME_MINUTES=99999/'

# And it must name the deficit rather than vetoing silently, so a morning
# shutdown that should not have happened is diagnosable from the journal alone.
check "the uptime veto reports the actual uptime" "uptime  " \
    's/^MIN_UPTIME_MINUTES=.*/MIN_UPTIME_MINUTES=99999/'

# A zero minimum must not veto, or the guard would pin the box awake forever
# and every overnight shutdown would stop working.
#
# Asserted as the ABSENCE of the uptime veto, not as "Idle on every signal".
# The first version demanded the whole box be idle, which was true only while
# nothing ran on it -- it started failing the moment bobgpt became a real
# service whose requests legitimately veto. A test for one signal must not
# depend on every other signal being quiet.
check_absent "uptime over the minimum does not veto" "under the" \
    's/^MIN_UPTIME_MINUTES=.*/MIN_UPTIME_MINUTES=0/'

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
echo "== completion request matching =="

# Shared by the llama-swap and bobgpt signals. The regex is the part that can
# actually be wrong, and it had no coverage at all before: /v1/models must NOT
# count, because Open WebUI polls it to build the model dropdown and
# verify.yml calls it on every apply -- counting those would keep the box
# awake on its own monitoring, forever, and look like real traffic.
#
# Extracted from the INSTALLED script so this cannot pass against a stale copy.
req_prog=$(sed -n '/^completion_request_lines()/,/^}/p' "$REAL" | sed -n "s/.*grep -cE '\(.*\)'.*/\1/p")
if [[ -z "$req_prog" ]]; then
    echo "FAIL  could not extract completion_request_lines regex from $REAL"
    fail=$(( fail + 1 ))
else
    # label, expected count, fixture log lines
    req_case() {
        local label="$1" want="$2"; shift 2
        local got
        got=$(printf '%s\n' "$@" | grep -cE "$req_prog")
        if [[ "$got" == "$want" ]]; then
            echo "PASS  $label"
            pass=$(( pass + 1 ))
        else
            echo "FAIL  $label -- expected $want, got $got"
            fail=$(( fail + 1 ))
        fi
    }

    # uvicorn's access log format, which is what bobgpt will emit.
    req_case "uvicorn chat completion counts" 1 \
        'INFO:     127.0.0.1:52344 - "POST /v1/chat/completions HTTP/1.1" 200 OK'
    req_case "a plain completion counts" 1 \
        'INFO:     127.0.0.1:52344 - "POST /v1/completions HTTP/1.1" 200 OK'
    req_case "embeddings count" 1 \
        'INFO:     127.0.0.1:52344 - "POST /v1/embeddings HTTP/1.1" 200 OK'

    # The exclusion that keeps the box from pinning itself awake.
    req_case "/v1/models does not count" 0 \
        'INFO:     127.0.0.1:52344 - "GET /v1/models HTTP/1.1" 200 OK'
    req_case "an unrelated line does not count" 0 \
        'INFO:     Application startup complete.'
    req_case "a health probe does not count" 0 \
        'INFO:     127.0.0.1:52344 - "GET /health HTTP/1.1" 200 OK'

    req_case "a busy window counts every request" 3 \
        'INFO:     127.0.0.1:1 - "POST /v1/chat/completions HTTP/1.1" 200 OK' \
        'INFO:     127.0.0.1:2 - "GET /v1/models HTTP/1.1" 200 OK' \
        'INFO:     127.0.0.1:3 - "POST /v1/chat/completions HTTP/1.1" 200 OK' \
        'INFO:     127.0.0.1:4 - "POST /v1/completions HTTP/1.1" 200 OK'
fi

echo
echo "== bobgpt activity =="

# An unset unit must report "not installed" and must NOT veto, or a host
# without bobgpt could never shut down.
check "no bobgpt unit does not veto" "bobgpt inference         not installed" \
    's/^BOBGPT_UNIT=.*/BOBGPT_UNIT=""/'

# Pointed at a real unit it must read the journal and report a count rather
# than erroring. systemd-journald always exists and serves no completions, so
# the expected count is zero -- this proves the branch runs, and the regex
# cases above prove what it matches.
check "a configured bobgpt unit is read" "bobgpt inference         0 request(s)" \
    's/^BOBGPT_UNIT=.*/BOBGPT_UNIT="systemd-journald.service"/'

echo
echo "== gpu exclusion filter =="

# bobgpt is a resident GPU service, and a CUDA context lives for the life of
# the process once initialised -- so it would appear in nvidia-smi forever and
# veto every overnight shutdown. It is excluded by cgroup, by identity, rather
# than by turning the GPU check off, so any OTHER process holding a context
# still vetoes. That distinction is the entire point of this signal and these
# cases exist to keep it.
#
# Extracted from the INSTALLED script so this cannot pass against a stale copy.
excl_prog=$(sed -n '/^not_excluded()/,/^}/p' "$REAL" | sed -n "s/.*awk -v ex=\"\$1\" '\(.*\)'.*/\1/p")
if [[ -z "$excl_prog" ]]; then
    echo "FAIL  could not extract not_excluded filter from $REAL"
    fail=$(( fail + 1 ))
else
    # label, exclusion list, expected surviving count, pid fixtures
    excl_case() {
        local label="$1" ex="$2" want="$3"; shift 3
        local got
        got=$(printf '%s\n' "$@" | awk -v ex="$ex" "$excl_prog" | grep -c .)
        if [[ "$got" == "$want" ]]; then
            echo "PASS  $label"
            pass=$(( pass + 1 ))
        else
            echo "FAIL  $label -- expected $want, got $got"
            fail=$(( fail + 1 ))
        fi
    }

    # The inverted case is the dangerous one. If an empty list excluded
    # everything, the GPU veto would silently switch off on every host that
    # has no bobgpt, and the only symptom would be a box that stops refusing
    # to power off mid-training.
    excl_case "empty exclusion keeps every pid" "" 2 "1234" "5678"
    excl_case "an excluded pid is dropped" "5678" 1 "1234" "5678"
    excl_case "a foreign pid still vetoes" "5678" 1 "1234"
    excl_case "every pid excluded counts zero" "1234 5678" 0 "1234" "5678"
    # Substring, not identity: pid 5678 is not pid 567.
    excl_case "a pid containing an excluded pid is not excluded" "567" 2 "5678" "1234"
    # nvidia-smi prints nothing when no process holds a context.
    excl_case "no gpu processes counts zero" "" 0
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
