#!/usr/bin/env bash
# Opt-in live guard for the Herdr secondmate pane-takeover gate.
#
# The gate's verdict comes from data Herdr itself emits - a pane's shell pid,
# its terminal foreground process group, and the pid, name, and argv0 of the
# process holding that group - so no fixture can prove the classifier still
# reads real Herdr correctly. The portable regression in
# tests/fm-backend-herdr.test.sh pins the classifier's logic with real
# processes and canned process-info; this guard drives a REAL pane through
# each of the four states that classifier separates and checks the verdict
# Herdr's own output produces, failing with the backend and version named.
#
# It is opt-in because standard CI has no Herdr binary and no terminal server.
# Run it after every Herdr upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Secondmate pane-takeover gate" entry.
#
# Every Herdr call is scoped to a named non-default lab session provisioned
# through bin/fm-herdr-lab.sh, whose teardown re-verifies that the captain's
# own default session is untouched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# cleanup_all is defined once the lab session exists, which is before the first
# fail call below; every earlier exit path reports and exits directly.
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_TAKEOVER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_TAKEOVER_LIVE_E2E=1 to run the real-Herdr pane-takeover guard"
  exit 0
fi

# An absent backend is reported, never passed over silently: this guard's whole
# subject is the installed Herdr's own output.
command -v herdr >/dev/null 2>&1 \
  || { echo "skip: the herdr backend is not installed, so its pane-takeover gate is unverified here"; exit 0; }
command -v jq >/dev/null 2>&1 \
  || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "not ok - fm_backend_source herdr failed" >&2; exit 1; }

SESSION=$(fm_herdr_lab_name takeover-live) || { echo "not ok - could not name a lab session" >&2; exit 1; }
PROVISIONED=0
cleanup_all() {
  [ "$PROVISIONED" = 1 ] || return 0
  PROVISIONED=0
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT

fm_herdr_lab_provision "$SESSION" || { echo "not ok - could not provision the isolated Herdr lab session" >&2; exit 1; }
PROVISIONED=1

HERDR_VERSION=$(fm_herdr_lab_cli "$SESSION" status --json 2>/dev/null | jq -r '.client.version // "unknown"')
BACKEND_ID="herdr backend, herdr $HERDR_VERSION"

# A generous settle budget: this guard deliberately drives a pane through
# seconds of shell work, and a loaded machine must not turn that into a flake.
export FM_BACKEND_HERDR_PANE_SETTLE_POLLS=200

CHECKED=0

# Prints the new pane's id, or nothing when any step fails. It never calls fail
# itself: it runs inside a command substitution, where an exit would end only
# the subshell and a teardown would run there and again in the real one. Each
# caller checks the printed id instead.
new_pane() {  # <label> -> pane id, empty on failure
  local out ws
  out=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd /tmp --label "$1" 2>/dev/null) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
  [ -n "$ws" ] || ws=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null \
    | jq -r --arg l "$1" '.result.workspaces[] | select(.label == $l) | .workspace_id' 2>/dev/null | tail -1)
  [ -n "$ws" ] || return 1
  fm_backend_herdr_cli "$SESSION" pane list --workspace "$ws" 2>/dev/null \
    | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null
}

wait_for_rest() {  # <pane>
  local i=0
  while [ "$i" -lt 200 ]; do
    [ "$(fm_backend_herdr_pane_foreground_state "$SESSION" "$1" 2>/dev/null || true)" != rest ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

verdict() {  # <pane> -> takeover:<name> | clear
  if fm_backend_herdr_pane_foreground_takeover "$SESSION" "$1"; then
    printf 'takeover:%s' "$FM_BACKEND_HERDR_TAKEOVER_PROCESS"
  else
    printf 'clear'
  fi
}

# --- a pane whose shell sits at its prompt is cleared -------------------------
PANE=$(new_pane fm-takeover-idle)
[ -n "$PANE" ] || fail "$BACKEND_ID: no pane id for the idle-shell case"
wait_for_rest "$PANE" || fail "$BACKEND_ID: a freshly created pane never reached its prompt"
GOT=$(verdict "$PANE")
[ "$GOT" = clear ] || fail "$BACKEND_ID: an idle shell at its prompt read as '$GOT'"
CHECKED=$((CHECKED + 1))
pass "$BACKEND_ID: a pane whose shell sits at its prompt is cleared"

# --- an ordinary foreground child is cleared, not refused ---------------------
# The false-refusal class: any rc that runs a foreground external command long
# enough (nvm use, a pyenv shell-out, a keychain lookup) put that command alone
# in the terminal's foreground group and the spawn aborted claiming a shell rc
# had exec'd it. Nothing exec's anything here.
PANE=$(new_pane fm-takeover-child)
[ -n "$PANE" ] || fail "$BACKEND_ID: no pane id for the foreground-child case"
wait_for_rest "$PANE" || fail "$BACKEND_ID: the foreground-child pane never reached its prompt"
fm_backend_herdr_cli "$SESSION" pane run "$PANE" 'sleep 6' >/dev/null 2>&1 \
  || fail "$BACKEND_ID: could not run a foreground command in the pane"
CHILD_SEEN=0
for _ in $(seq 1 60); do
  if fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null \
    | jq -e '.result.process_info
      | (.foreground_processes | length) == 1
      and .foreground_processes[0].name == "sleep"
      and .foreground_process_group_id != .shell_pid
      and .foreground_processes[0].pid != .shell_pid' >/dev/null 2>&1; then
    CHILD_SEEN=1
    break
  fi
  sleep 0.1
done
[ "$CHILD_SEEN" = 1 ] \
  || fail "$BACKEND_ID: never observed an ordinary foreground child owning the pane's terminal group, so the false-refusal case could not be exercised"
GOT=$(verdict "$PANE")
[ "$GOT" = clear ] \
  || fail "$BACKEND_ID: an ordinary foreground child read as '$GOT', refusing a legitimate spawn"
CHECKED=$((CHECKED + 1))
pass "$BACKEND_ID: an ordinary foreground rc command is cleared, not refused as a takeover"

# --- a genuine exec takeover is still refused ---------------------------------
PANE=$(new_pane fm-takeover-exec)
[ -n "$PANE" ] || fail "$BACKEND_ID: no pane id for the exec case"
wait_for_rest "$PANE" || fail "$BACKEND_ID: the exec pane never reached its prompt"
fm_backend_herdr_cli "$SESSION" pane run "$PANE" 'exec /usr/bin/tail -f /dev/null' >/dev/null 2>&1 \
  || fail "$BACKEND_ID: could not run the exec command in the pane"
GOT=$(verdict "$PANE")
[ "$GOT" = takeover:tail ] \
  || fail "$BACKEND_ID: a shell that exec'd tail read as '$GOT' instead of a takeover"
CHECKED=$((CHECKED + 1))
pass "$BACKEND_ID: a shell replaced by another program through exec is refused"

# --- an rc that works first and execs later is still refused ------------------
# The silent-corruption case: while the shell does pure-shell work it remains
# the pane's sole foreground process under its own pid, so a verdict taken in
# the first fraction of a second clears the pane and the launch command lands
# in whatever the rc goes on to exec.
PANE=$(new_pane fm-takeover-late-exec)
[ -n "$PANE" ] || fail "$BACKEND_ID: no pane id for the late-exec case"
wait_for_rest "$PANE" || fail "$BACKEND_ID: the late-exec pane never reached its prompt"
# shellcheck disable=SC2016  # the pane's own shell expands this, not the test's
fm_backend_herdr_cli "$SESSION" pane run "$PANE" \
  'i=0; while [ $i -lt 800000 ]; do i=$((i+1)); done; exec /usr/bin/tail -f /dev/null' >/dev/null 2>&1 \
  || fail "$BACKEND_ID: could not run the late-exec command in the pane"
BUSY_SEEN=0
LAST_SAMPLE=
for _ in $(seq 1 60); do
  LAST_SAMPLE=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null \
    | jq -c '.result.process_info
      | {shell_pid, foreground_process_group_id, foreground: [.foreground_processes[] | {name, pid}]}' 2>/dev/null)
  if printf '%s' "$LAST_SAMPLE" | jq -e '
    (.foreground | length) == 1
    and .foreground_process_group_id == .shell_pid
    and .foreground[0].pid == .shell_pid
    and (.foreground[0].name | test("^(sh|bash|zsh|dash|ksh|fish)$"))' >/dev/null 2>&1; then
    BUSY_SEEN=1
    break
  fi
  sleep 0.05
done
[ "$BUSY_SEEN" = 1 ] \
  || fail "$BACKEND_ID: the pane never read as an ordinary shell after the rc-shaped command started, so the late-exec case could not be exercised; last sample: ${LAST_SAMPLE:-<unreadable>}"
GOT=$(verdict "$PANE")
[ "$GOT" = takeover:tail ] \
  || fail "$BACKEND_ID: a shell that read as an ordinary shell and exec'd tail afterwards read as '$GOT'; the gate cleared a pane before the substitution it exists to catch"
CHECKED=$((CHECKED + 1))
pass "$BACKEND_ID: a shell that works first and execs afterwards is still refused"

[ "$CHECKED" -eq 4 ] \
  || fail "$BACKEND_ID: the pane-takeover guard checked only $CHECKED of 4 states; a pass that verified nothing is not a pass"
printf 'evidence: backend=herdr version=%s states_checked=%s\n' "$HERDR_VERSION" "$CHECKED"
