#!/usr/bin/env bash
# tests/fm-herdr-submit-busy.test.sh - Herdr busy-queued Enter.
#
# An agent that is mid-turn (Claude Code, OpenCode) accepts Enter as "send when
# this turn ends" but keeps the typed text in its composer until then. Herdr's
# submit check used to read that as a swallowed Enter, so fm-send exited 1 for
# a message the agent did receive, inviting a duplicate resend and leaving a
# --resolve-key decision open. This mirrors tests/fm-tmux-submit-busy.test.sh
# for the Herdr adapter and drives the real fm-send executable over a stateful
# fake `herdr` CLI:
#   - adapter: busy + text left -> queued; idle + text left -> pending;
#     busy + composer cleared -> empty; idle + cleared -> empty; unknown busy
#     state + text left -> pending; blocked (a dialog) + text left -> pending.
#   - fm-send: a queued send exits 0, prints a `queued:` line, and closes a
#     --resolve-key decision; the task's semantic busy source also proves a
#     queue when native state reads idle; an idle target stays a failure that
#     closes nothing; a remote host's queued outcome crosses the transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
herdr_forget_inherited_pane

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-submit-busy)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
export FM_BACKEND_HERDR_SUBMIT_POLLS=1

PENDING_ROW='  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ─────╯\n'
EMPTY_ROW='  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯\n'

# make_fake_herdr <dir>: a stateful `herdr` stub. The composer lives in
# $FM_FAKE_COMPOSER and is what `pane read` returns. `pane send-keys <p> enter`
# clears it unless $FM_FAKE_KEEP_TEXT=1 (the busy agent keeps queued text
# visible). `agent get` reports $FM_FAKE_AGENT_BEFORE until the first Enter and
# $FM_FAKE_AGENT_AFTER after it; the value `fail` makes the read exit 1.
make_fake_herdr() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
entered="${FM_FAKE_COMPOSER:?}.entered"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-text") : ;;
  "pane send-keys")
    if [ "${4:-}" = enter ]; then
      touch "$entered"
      [ "${FM_FAKE_KEEP_TEXT:-0}" = 1 ] || printf '%b' "$FM_FAKE_EMPTY_ROW" > "$FM_FAKE_COMPOSER"
    fi
    ;;
  "pane read") cat "$FM_FAKE_COMPOSER" ;;
  "agent get")
    if [ -e "$entered" ]; then s=${FM_FAKE_AGENT_AFTER:-idle}; else s=${FM_FAKE_AGENT_BEFORE:-idle}; fi
    [ "$s" = fail ] && exit 1
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$s"
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
[ -z "${FM_FAKE_SSH_STDERR:-}" ] || printf '%s\n' "$FM_FAKE_SSH_STDERR" >&2
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# case_env <name>: fresh dir with fakebin and a composer holding typed text.
case_env() {  # <name> -> sets DIR FB
  DIR="$TMP_ROOT/$1"
  mkdir -p "$DIR"
  FB=$(make_fake_herdr "$DIR")
  : > "$DIR/herdr.log"
  printf '%b' "$PENDING_ROW" > "$DIR/composer"
}

# submit <before> <after> <keep-text>: run the adapter submit, echo its verdict.
submit() {
  PATH="$FB:$PATH" FM_HERDR_LOG="$DIR/herdr.log" FM_FAKE_COMPOSER="$DIR/composer" \
    FM_FAKE_EMPTY_ROW="$EMPTY_ROW" FM_FAKE_AGENT_BEFORE="$1" FM_FAKE_AGENT_AFTER="$2" FM_FAKE_KEEP_TEXT="$3" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0' "$ROOT"
}

enter_count() {
  grep -c 'pane send-keys w1:p2 enter' "$DIR/herdr.log" || true
}

test_busy_text_left_is_queued() {
  local out
  case_env busy-left
  out=$(submit working working 1)
  [ "$out" = queued ] || fail "busy agent + text left after Enter should be queued, got '$out'"
  [ "$(enter_count)" -eq 3 ] || fail "the full Enter retry budget should run before the queue fallback, sent $(enter_count)"
  pass "herdr submit: a working agent with text still in the composer reports queued"
}

test_idle_text_left_is_pending() {
  local out
  case_env idle-left
  out=$(submit idle idle 1)
  [ "$out" = pending ] || fail "idle agent + text left should stay pending, got '$out'"
  case_env busy-then-idle-left
  out=$(submit working idle 1)
  [ "$out" = pending ] || fail "an agent idle by the end with text left should stay pending, got '$out'"
  pass "herdr submit: an idle agent with text left in the composer is still a genuine failure"
}

test_busy_cleared_is_empty() {
  local out
  case_env busy-cleared
  out=$(submit working working 0)
  [ "$out" = empty ] || fail "busy agent + cleared composer should be empty, got '$out'"
  [ "$(enter_count)" -eq 1 ] || fail "a cleared composer needs one Enter, sent $(enter_count)"
  pass "herdr submit: a working agent whose composer clears reports empty"
}

test_idle_cleared_is_empty() {
  local out
  case_env idle-cleared
  out=$(submit idle working 0)
  [ "$out" = empty ] || fail "idle agent that starts a turn should be empty, got '$out'"
  case_env unread-cleared
  out=$(submit fail fail 0)
  [ "$out" = empty ] || fail "an unreadable native state with a cleared composer should be empty, got '$out'"
  pass "herdr submit: an idle agent whose Enter lands reports empty"
}

test_unknown_text_left_is_pending() {
  local out
  case_env unknown-left
  out=$(submit fail fail 1)
  [ "$out" = pending ] || fail "unknown busy state + text left should stay pending, got '$out'"
  case_env blocked-left
  out=$(submit blocked blocked 1)
  [ "$out" = pending ] || fail "a blocked agent (a dialog) + text left must not be queued, got '$out'"
  pass "herdr submit: an unknown or blocked agent with text left is still a failure"
}

# --- fm-send end to end -------------------------------------------------------

setup_home() {  # <name> <harness> -> echoes a home with a recorded Herdr task t1
  local home="$TMP_ROOT/home-$1"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/t1.meta" "window=default:w1:p2" "backend=herdr" \
    "herdr_session=default" "herdr_pane_id=w1:p2" "kind=ship" "harness=$2"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf '%s\n' "$home"
}

run_send() {  # <home> <before> <after> <keep-text> <args...>; stderr -> $DIR/err
  local home=$1 before=$2 after=$3 keep=$4
  shift 4
  env PATH="$FB:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_HERDR_LOG="$DIR/herdr.log" FM_FAKE_COMPOSER="$DIR/composer" FM_FAKE_EMPTY_ROW="$EMPTY_ROW" \
    FM_FAKE_AGENT_BEFORE="$before" FM_FAKE_AGENT_AFTER="$after" FM_FAKE_KEEP_TEXT="$keep" \
    "$SEND" "$@" </dev/null >/dev/null 2>"$DIR/err"
}

decision_open() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null | grep -F '[key=api-shape]' >/dev/null
}

test_fm_send_queued_closes_resolve_key() {
  local home rc
  case_env send-queued
  home=$(setup_home send-queued claude)
  run_send "$home" working working 1 t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "a queued send is a delivery and must exit 0"$'\n'"$(cat "$DIR/err")"
  assert_grep 'queued: text reached default:w1:p2' "$DIR/err" "fm-send should say the text was queued behind a running turn"
  assert_no_grep 'not submitted' "$DIR/err" "a queued send must not report a failure"
  grep -F 'resolved [key=api-shape]: answered: go with REST' "$home/state/t1.status" >/dev/null \
    || fail "a queued answer should close its decision:"$'\n'"$(cat "$home/state/t1.status")"
  decision_open "$home" && fail "the answered decision still lists as open after a queued send"
  pass "fm-send: a queued Herdr send exits 0, says queued, and closes its --resolve-key decision"
}

test_fm_send_submitted_does_not_say_queued() {
  local home rc
  case_env send-submitted
  home=$(setup_home send-submitted claude)
  run_send "$home" idle working 0 t1 "hello"; rc=$?
  expect_code 0 "$rc" "an ordinary submit should succeed"
  assert_no_grep 'queued:' "$DIR/err" "an immediate submit must not be reported as queued"
  pass "fm-send: an immediate Herdr submit is not reported as queued"
}

test_fm_send_semantic_busy_proves_queue() {
  local home rc
  case_env send-semantic
  home=$(setup_home send-semantic claude)
  "$BUSY_EVENT" arm "$home/state" t1 --state busy --source claude-hook --event UserPromptSubmit >/dev/null \
    || fail "could not arm the semantic busy record"
  # Native state reads idle throughout, as during a long foreground tool call.
  run_send "$home" idle idle 1 t1 --resolve-key api-shape "go with REST"; rc=$?
  expect_code 0 "$rc" "a semantic-busy target with text left should be queued"$'\n'"$(cat "$DIR/err")"
  assert_grep 'queued: ' "$DIR/err" "the semantic-busy queue should be reported"
  decision_open "$home" && fail "the decision should close on a semantic-busy queued send"
  pass "fm-send: the task's semantic busy source proves a queue when native state reads idle"
}

test_fm_send_idle_text_left_fails_and_keeps_decision() {
  local home rc
  case_env send-idle
  home=$(setup_home send-idle claude)
  "$BUSY_EVENT" arm "$home/state" t1 --state idle --source claude-hook --event Stop >/dev/null \
    || fail "could not arm the semantic idle record"
  run_send "$home" idle idle 1 t1 --resolve-key api-shape "go with REST"; rc=$?
  [ "$rc" -ne 0 ] || fail "an idle target with text left must fail"
  assert_grep 'not submitted' "$DIR/err" "the idle failure should be reported as not submitted"
  assert_no_grep 'queued:' "$DIR/err" "an idle failure must not claim a queue"
  decision_open "$home" || fail "an unconfirmed send must leave the decision open"
  case_env send-unknown
  home=$(setup_home send-unknown claude)
  run_send "$home" fail fail 1 t1 --resolve-key api-shape "go with REST"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown-state target with no busy record and text left must fail"
  decision_open "$home" || fail "an unknown-state failure must leave the decision open"
  pass "fm-send: an idle or unknown Herdr target with text left still fails and closes nothing"
}

test_fm_send_remote_queued_crosses_transport() {
  local home rc ssh_log
  case_env send-remote
  ssh_log="$DIR/ssh.log"; : > "$ssh_log"
  home="$TMP_ROOT/home-remote"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/rsm.meta" "window=fm-remote:w1:p1" "endpoint_task_id=rsm" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "remote_host=remote-mac" "remote_root=/remote/root" "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" "remote_target=fm-remote:w1:p1"
  printf -- '- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)\n' \
    > "$home/data/secondmates.md"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/rsm.status"
  env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$FB/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    FM_FAKE_SSH_STDERR="queued: text reached fm-remote:w1:p1 while its agent was mid-turn and is waiting in its composer; it submits when that turn ends. Delivered - do not resend." \
    "$SEND" rsm --resolve-key api-shape "go with REST" </dev/null >/dev/null 2>"$DIR/err"; rc=$?
  expect_code 0 "$rc" "a remote queued send should succeed"$'\n'"$(cat "$DIR/err")"
  assert_grep 'queued: text reached remote:rsm' "$DIR/err" "the remote target's queued outcome should be reported on this side"
  decision_open "$home" && fail "a remote queued answer should close its decision"
  pass "fm-send: a remote host's queued delivery is reported for the remote target and closes the decision"
}

test_busy_text_left_is_queued
test_idle_text_left_is_pending
test_busy_cleared_is_empty
test_idle_cleared_is_empty
test_unknown_text_left_is_pending
test_fm_send_queued_closes_resolve_key
test_fm_send_submitted_does_not_say_queued
test_fm_send_semantic_busy_proves_queue
test_fm_send_idle_text_left_fails_and_keeps_decision
test_fm_send_remote_queued_crosses_transport
