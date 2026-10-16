#!/usr/bin/env bash
# Unit tests for roles/bobgpt/files/bobgpt-logs.
#
# That script runs as root on a CI account's say-so, and the ONLY thing keeping
# the grant scoped to one unit is its argument handling: the unit name is a
# constant, and a caller may choose a line count and nothing else. So the
# interesting cases are all rejections -- every way of smuggling an option past
# the digits test is a way to read the rest of the journal.
#
# The accept path cannot be tested here: the script execs an absolute
# /usr/bin/journalctl, deliberately, so there is nothing to stub. What is
# asserted instead is that a valid argument gets PAST validation (it reaches
# journalctl, whatever that then says). The real read is proved on the host by
# the bobgpt assertions in hosts/lab/verify.yml.
#
# Modelled on scripts/test_sonarqube_deploy.sh. Run from anywhere:
#   ./scripts/test_bobgpt_logs.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/roles/bobgpt/files/bobgpt-logs"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
nope() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Exit 64 is EX_USAGE, which is what the script's usage() returns.
refuses() {
  local desc=$1; shift
  local out rc
  out=$("$SCRIPT" "$@" 2>&1); rc=$?
  if [ "$rc" -ne 64 ]; then
    nope "$desc" "expected exit 64, got $rc: ${out:0:120}"
  elif [ -n "$out" ] && ! printf '%s' "$out" | grep -qi usage; then
    nope "$desc" "refused but printed no usage: ${out:0:120}"
  else
    ok "$desc"
  fi
}

# Past validation means NOT 64. The exec'd journalctl may then fail for its own
# reasons (no such unit on a workstation, no permission), and that is fine --
# this asserts only that the script did not reject the argument.
accepts() {
  local desc=$1; shift
  local out rc
  out=$("$SCRIPT" "$@" 2>&1); rc=$?
  if [ "$rc" -eq 64 ]; then
    nope "$desc" "rejected a valid argument: ${out:0:120}"
  else
    ok "$desc"
  fi
}

[ -x "$SCRIPT" ] || { echo "not executable: $SCRIPT" >&2; exit 1; }

# The whole point: another unit's name must not reach journalctl.
refuses 'refuses a second unit (-u ssh)'            -u ssh
refuses 'refuses a unit name alone'                 ssh
refuses 'refuses --unit=ssh'                        --unit=ssh
refuses 'refuses a time window'                     --since=-1h
refuses 'refuses follow mode'                       -f
refuses 'refuses an output format'                  --output=json
refuses 'refuses a journal path'                    --file=/var/log/journal
refuses 'refuses the kernel ring buffer'            -k
refuses 'refuses a flag disguised as a count'       -200
refuses 'refuses a count with a flag attached'      '200 -u ssh'
refuses 'refuses two arguments'                     200 -u
refuses 'refuses an empty argument'                 ''
refuses 'refuses a non-numeric count'               abc
refuses 'refuses a decimal count'                   1.5
refuses 'refuses zero lines'                        0
refuses 'refuses a count above the cap'             5001
refuses 'refuses a shell metacharacter'             '200;id'

accepts 'accepts no argument'
accepts 'accepts a line count'                      5
accepts 'accepts the cap exactly'                   5000

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
