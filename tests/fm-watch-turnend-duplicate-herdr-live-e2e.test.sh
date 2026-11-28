#!/usr/bin/env bash
# Real Claude/Herdr regression for the turn-end duplicate stale.
#
# Opt-in because it launches a real interactive Claude Code worker, which makes
# real model requests, inside a real isolated Herdr lab session.
# A worker that appended `done:` and ended its turn used to cost firstmate two
# wakes: the turn-end signal, then a bare "stale: <window>" for the same idle
# pane once the watcher re-armed.
# This test drives the production watcher through several re-arms against that
# real idle pane and proves:
#   - exactly one wake (the turn-end signal) and no bare stale reach the queue,
#     and the watcher logged the absorbed duplicate, so the check is not vacuous;
#   - a draft typed into the composer afterwards still surfaces a stale;
#   - the agent exiting to its shell afterwards still surfaces a stale.
#
# The worker's metadata and lifecycle hooks mirror what bin/fm-spawn.sh writes
# for a Claude task, without allocating a treehouse worktree outside the test's
# own temporary root.
# Every Herdr call, including the production adapter's, goes through
# bin/fm-herdr-lab.sh, exactly as tests/fm-send-secondmate-marker-herdr-e2e.test.sh
# routes them.
# The watcher runs with its production poll and signal-grace defaults unless
# FM_POLL or FM_SIGNAL_GRACE are set, because the duplicate is decided by how
# quickly the real pane settles inside that grace.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_WATCH_TURNEND_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_WATCH_TURNEND_HERDR_E2E=1 to run the real Claude/Herdr turn-end duplicate regression"
  exit 0
fi

for tool in git herdr jq claude; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

# A run from inside a live fleet pane inherits that pane's Herdr identity, including the fleet server's socket.
# It is dropped here so nothing this test starts can reach the fleet except through the lab helper.
INHERITED_SOCKET=${HERDR_SOCKET_PATH:-}
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# A run from inside a Claude Code session also inherits that session's identity and messaging socket.
# The lab server and the worker Claude are started without it, so the worker cannot attach to the running session.
CLAUDE_SESSION_UNSET=()
while IFS='=' read -r name _; do
  case "$name" in
    CLAUDECODE|CLAUDE_CODE_*|CLAUDE_PID|CLAUDE_EFFORT) CLAUDE_SESSION_UNSET+=(-u "$name") ;;
  esac
done < <(env)

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-turnend-dup)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-turnend-dup-herdr-e2e.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ROUNDS_LOG="$TMP_ROOT/rounds.log"
ORIGINAL_PATH=$PATH
ID='turnend-dup'
MODEL=${FM_WATCH_TURNEND_E2E_MODEL:-claude-haiku-5-5}
IDLE_ROUNDS=${FM_WATCH_TURNEND_E2E_IDLE_ROUNDS:-3}
ROUND_SECS=${FM_WATCH_TURNEND_E2E_ROUND_SECS:-120}
TURN_SECS=${FM_WATCH_TURNEND_E2E_TURN_SECS:-20}
WATCH_PID=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  if [ "$rc" -ne 0 ] && [ -f "$ROUNDS_LOG" ]; then
    echo "--- rounds" >&2
    cat "$ROUNDS_LOG" >&2
    echo "--- wake queue" >&2
    cat "$STATE/.wake-queue" >&2 2>/dev/null || true
    echo "--- triage log" >&2
    cat "$STATE/.watch-triage.log" >&2 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$PROJECT" "$FAKEBIN"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
pane_text() { lab pane read "$PANE" --source recent --lines 200 2>/dev/null | tail -n 40; }

git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init

env ${CLAUDE_SESSION_UNSET[@]+"${CLAUDE_SESSION_UNSET[@]}"} "$LAB_HELPER" provision "$SESSION"
OUT=$(env ${CLAUDE_SESSION_UNSET[@]+"${CLAUDE_SESSION_UNSET[@]}"} "$LAB_HELPER" run "$SESSION" \
  workspace create --cwd "$PROJECT" --label "fm-$ID" --no-focus) || fail "could not create the lab workspace"
WS=$(printf '%s' "$OUT" | jq -r '.result.workspace.workspace_id')
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "the lab workspace reported no root pane: $OUT"
TARGET="$SESSION:$PANE"

# The lab pane must carry the lab server's own socket, never the fleet's, before a real agent runs in it.
# The answer is printed as a short word because a long socket path would wrap in the pane.
# The quotes split each word in the echoed command line, so only the answer itself matches.
# shellcheck disable=SC2016  # the lab pane's shell expands these, not this script
PROBE=$(printf 'if [ -n "$HERDR_SOCKET_PATH" ] && [ "$HERDR_SOCKET_PATH" != %q ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then echo fm-env-"clean"; else echo fm-env-"tainted"; fi' "$INHERITED_SOCKET")
lab pane run "$PANE" "$PROBE" >/dev/null || fail "could not probe the lab pane's environment"
probe=
for _ in $(seq 1 30); do
  probe=$(pane_text | grep -o 'fm-env-clean\|fm-env-tainted' | tail -n 1)
  [ -n "$probe" ] && break
  sleep 1
done
[ "$probe" = fm-env-clean ] \
  || fail "the lab pane lacks its own Herdr socket, carries the fleet's, or inherited this Claude session's identity: ${probe:-no answer} $(pane_text)"

# The lifecycle hooks bin/fm-spawn.sh writes for a Claude task.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || fail "could not arm the lifecycle record"
TURNEND="$STATE/$ID.turn-ended"
pre="$(printf '%q' "$ROOT/bin/fm-busy-event.sh") apply $(printf '%q' "$STATE") $(printf '%q' "$ID")"
suf="--gen $(printf '%q' "$GEN") --source claude-hook"
mkdir -p "$PROJECT/.claude"
jq -n --arg s "$pre busy $suf --event user-prompt-submit 2>/dev/null || true" \
  --arg t "touch $(printf '%q' "$TURNEND"); $pre idle $suf --event stop 2>/dev/null || true" \
  --arg f "$pre idle $suf --event stop-failure 2>/dev/null || true" \
  --arg e "$pre idle $suf --event session-end 2>/dev/null || true" \
  '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$s}]}],Stop:[{hooks:[{type:"command",command:$t}]}],StopFailure:[{hooks:[{type:"command",command:$f}]}],SessionEnd:[{hooks:[{type:"command",command:$e}]}]}}' \
  > "$PROJECT/.claude/settings.local.json"
cat > "$STATE/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$PROJECT
project=$PROJECT
harness=claude
kind=scout
model=$MODEL
busy_gen=$GEN
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_pane_id=$PANE
EOF

STATUS_LINE='done: PR https://example.invalid/pr/1 checks green'
PROMPT="Run this exact shell command and nothing else: echo '$STATUS_LINE' >> '$STATE/$ID.status' . Then reply with the single word OK and stop."
CLAUDE_ENV_PREFIX=''
for arg in ${CLAUDE_SESSION_UNSET[@]+"${CLAUDE_SESSION_UNSET[@]}"}; do
  CLAUDE_ENV_PREFIX="$CLAUDE_ENV_PREFIX $(printf '%q' "$arg")"
done
CMD=$(printf 'cd %q && env%s CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model %q %q' \
  "$PROJECT" "$CLAUDE_ENV_PREFIX" "$MODEL" "$PROMPT")
lab pane run "$PANE" "$CMD" >/dev/null || fail "could not launch Claude in the lab pane"

# Answer the first-launch folder-trust dialog, whose default is to exit.
trusted=0
for _ in $(seq 1 180); do
  text=$(pane_text)
  if [ "$trusted" -eq 0 ] && printf '%s' "$text" | grep -q 'Yes, I trust this folder'; then
    if printf '%s' "$text" | grep -q '❯ No, exit'; then
      lab pane send-keys "$PANE" down >/dev/null
      sleep 0.3
    fi
    lab pane send-keys "$PANE" enter >/dev/null
    trusted=1
  fi
  if printf '%s' "$text" | grep -q "Claude Code didn't start"; then
    fail "Claude refused to start in the lab pane: $text"
  fi
  if grep -qF "$STATUS_LINE" "$STATE/$ID.status" 2>/dev/null && [ -e "$TURNEND" ] \
    && grep -q 'state=idle' "$STATE/$ID.busy-state" 2>/dev/null; then
    break
  fi
  sleep 1
done
grep -qF "$STATUS_LINE" "$STATE/$ID.status" 2>/dev/null || fail "the real worker never wrote its done: line: $(pane_text)"
[ -e "$TURNEND" ] || fail "the real worker's Stop hook never touched turn-ended"
grep -q 'state=idle' "$STATE/$ID.busy-state" || fail "the real worker's lifecycle record never read idle: $(cat "$STATE/$ID.busy-state")"

# One watcher run: 0 when it exited with a wake, 1 when it was still blocking
# after <secs>.
# The host sleeping mid-run invalidates the timing, so that fails loudly.
watch_round() {  # <label> <secs>
  local label=$1 secs=$2 out="$TMP_ROOT/round-$1.out" start elapsed i=0 rc=1
  start=$(date +%s)
  env PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>>"$TMP_ROOT/watch.stderr" &
  WATCH_PID=$!
  while [ "$i" -lt "$secs" ]; do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      wait "$WATCH_PID" 2>/dev/null
      rc=0
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$rc" -ne 0 ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  WATCH_PID=
  elapsed=$(( $(date +%s) - start ))
  printf '%s\trc=%s\telapsed=%ss\t%s\n' "$label" "$rc" "$elapsed" "$(tr '\n' ' ' < "$out")" >> "$ROUNDS_LOG"
  [ "$elapsed" -le $((i + 30)) ] || fail "the host slept during watcher round $label (${elapsed}s wall time for ${i}s of polling); rerun with the host awake"
  ROUND_OUT=$(cat "$out")
  return "$rc"
}

firstmate_turn() {
  PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-peek.sh" "$ID" >/dev/null 2>&1 || true
  sleep "$TURN_SECS"
}

stale_records() {  # <exact payload or "any">
  awk -F '\t' -v w="$TARGET" -v want="$1" \
    '$3 == "stale" && $4 == w && (want == "any" || $5 == want) { n++ } END { print n + 0 }' "$STATE/.wake-queue" 2>/dev/null || printf '0\n'
}

watch_round signal 240 || fail "the turn-end signal never woke the watcher"
case "$ROUND_OUT" in
  "signal: "*"$ID.status"*|"signal: "*"$ID.turn-ended"*) : ;;
  *) fail "the first wake after the turn end was not its signal: $ROUND_OUT" ;;
esac
# One wake queues one record per signalled file and scan, which the drain merges by kind and key.
# So the proof of one wake is that every queued record is that signal and that nothing else is queued later.
[ "$(awk -F '\t' '$3 != "signal" { n++ } END { print n + 0 }' "$STATE/.wake-queue")" -eq 0 ] \
  || fail "the turn-end wake queued something other than its signal: $(cat "$STATE/.wake-queue")"
[ "$(awk -F '\t' '!($5 in p) { p[$5] = 1; n++ } END { print n + 0 }' "$STATE/.wake-queue")" -eq 1 ] \
  || fail "the turn-end wake queued more than one signal: $(cat "$STATE/.wake-queue")"
SIGNAL_RECORDS=$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')
firstmate_turn

round=1
while [ "$round" -le "$IDLE_ROUNDS" ]; do
  if watch_round "idle-$round" "$ROUND_SECS"; then
    fail "re-arm $round woke firstmate again for the idle pane its signal already reported: $ROUND_OUT"
  fi
  firstmate_turn
  round=$((round + 1))
done
[ "$(wc -l < "$STATE/.wake-queue" | tr -d '[:space:]')" -eq "$SIGNAL_RECORDS" ] \
  || fail "the idle re-arms queued a wake after the turn-end signal: $(cat "$STATE/.wake-queue")"
[ "$(stale_records any)" -eq 0 ] || fail "a stale wake reached the queue while the worker sat idle after its signal"
assert_grep "absorbed stale (same idle pane already surfaced by this task's signal): $TARGET" \
  "$STATE/.watch-triage.log" "the watcher never reached the duplicate it should absorb, so the idle rounds proved nothing"
pass "real Claude on Herdr: one turn-end signal, no bare stale across $IDLE_ROUNDS re-arms, duplicate absorbed"

lab pane send-text "$PANE" "please also rebase onto main" >/dev/null || fail "could not type the draft"
watch_round draft "$ROUND_SECS" || fail "a draft typed after the signal never surfaced"
[ "$ROUND_OUT" = "stale: $TARGET" ] || fail "the typed draft surfaced the wrong wake: $ROUND_OUT"
pass "real Claude on Herdr: a draft left in the composer after the signal still surfaces a stale"
firstmate_turn

lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "could not clear the draft"
sleep 0.5
lab pane send-text "$PANE" "/exit" >/dev/null || fail "could not type /exit"
sleep 0.5
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit /exit"
for _ in $(seq 1 60); do
  pane_text | grep -q 'Resume this session' && break
  sleep 1
done
pane_text | grep -q 'Resume this session' || fail "the real worker did not exit: $(pane_text)"
watch_round exit "$ROUND_SECS" || fail "the agent exiting to its shell never surfaced"
case "$ROUND_OUT" in
  "stale: $TARGET"*) : ;;
  *) fail "the agent exit surfaced the wrong wake: $ROUND_OUT" ;;
esac
pass "real Claude on Herdr: the agent exiting to its shell still surfaces a stale"

# The Herdr version is left to the caller's evidence, because every Herdr call here goes through the lab helper, which takes no global options.
printf 'evidence: claude %s, model %s\n' "$(claude --version 2>/dev/null)" "$MODEL"
cat "$ROUNDS_LOG"
