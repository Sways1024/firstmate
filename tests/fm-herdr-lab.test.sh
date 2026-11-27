#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
#
# The fake models two kinds of session. Sessions the helper did not create -
# the live fleet in any layout, plus any foreign or concurrent lab - live in
# others.json and change only when a test says so. Lab sessions the helper
# creates live in one state file each, named after the session. The fake
# records a violation whenever a call is scoped to, stops, or deletes a session
# in others.json, or arrives carrying the caller's inherited Herdr pane
# identity, so "never acts on a session it did not create" is checked on every
# case rather than inferred.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
DEFAULT_SOCKET=/home/test/.config/herdr/herdr.sock
FLEET_E_SOCKET=/home/test/.config/herdr/sessions/fleet-e/herdr.sock
mkdir -p "$FAKE_STATE"
: > "$FAKE_LOG"
: > "$FAKE_STATE/violations"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
call="$*"
# The isolation invariant (#1575): --session <name> must be present and must
# precede any literal `--` child-argv delimiter (after `--`, herdr would treat
# it as the child's argv and never apply it). Without `--` this still requires
# the historical trailing position.
session=
prev=
dd_seen=0
for arg in "$@"; do
  if [ "$prev" = --session ] && [ -z "$session" ]; then
    [ "$dd_seen" -eq 0 ] || { echo "fake herdr: --session after -- delimiter" >&2; exit 90; }
    session=$arg
  fi
  [ "$arg" != '--' ] || dd_seen=1
  prev=$arg
done
[ -n "$session" ] || { echo "fake herdr: missing --session" >&2; exit 90; }
if [ "$dd_seen" -eq 0 ] && [ "$prev" != "$session" ]; then
  echo "fake herdr: --session must trail when no -- delimiter is present" >&2
  exit 90
fi

not_ours() { # <name>: the session is one the helper did not create
  jq -e --arg n "$1" 'any(.[]; .name == $n)' "$state/others.json" >/dev/null
}
violation() { # <reason>
  printf '%s: %s\n' "$1" "$call" >> "$state/violations"
  echo "fake herdr: $1" >&2
  exit 94
}
mutate_others() { # <jq filter>
  jq -c "$1" "$state/others.json" > "$state/others.json.tmp"
  mv "$state/others.json.tmp" "$state/others.json"
}
# Every case runs as a worker inside a live fleet pane, so the caller's own
# pane identity, including the fleet server's socket, must never reach herdr.
for var in HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID; do
  # A builtin test, not printenv: the provision poll calls this fake hundreds of
  # times, and the timed-out-provision case needs those polls to stay cheap.
  [ -z "${!var+x}" ] || violation "inherited $var reached herdr"
done
[ "${HERDR_SESSION:-}" = "$session" ] \
  || violation "HERDR_SESSION '${HERDR_SESSION:-}' does not match --session '$session'"
# Listing sessions is read-only, and the helper lists under a candidate name to
# learn that the name is already taken; every other call must be its own lab's.
case "$1 ${2:-}" in
  "session list") ;;
  *) ! not_ours "$session" || violation "call scoped to a session the helper did not create" ;;
esac

lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    case "${FM_FAKE_HERDR_LIST_MODE:-}" in
      fail) echo "fake herdr: session list failed" >&2; exit 95 ;;
      garbage) printf '%s\n' 'not json'; exit 0 ;;
    esac
    labs='[]'
    for file in "$state"/fm-lab-*; do
      [ -f "$file" ] || continue
      lab=${file##*/}
      case "$(cat "$file")" in
        running) running=true ;;
        stopped) running=false ;;
        *) continue ;;
      esac
      # A test makes Herdr report a lab as the default session by writing
      # default-flag.<lab>, so refuse-default is exercised on a real listing.
      is_default=false
      [ ! -f "$state/default-flag.$lab" ] || is_default=true
      labs=$(printf '%s' "$labs" | jq -c --arg name "$lab" --argjson running "$running" \
        --argjson default "$is_default" \
        '. + [{default:$default,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]')
    done
    listing=$(jq -c --argjson labs "$labs" '{sessions:(. + $labs)}' "$state/others.json")
    printf '%s\n' "$listing"
    # multi: a reply holding more than one JSON document.
    [ "${FM_FAKE_HERDR_LIST_MODE:-}" != multi ] || printf '%s\n' "$listing"
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    ! not_ours "$3" || violation "stopped a session the helper did not create"
    [ "$3" = "$session" ] || exit 91
    [ "${FM_FAKE_HERDR_STOP_FAIL:-}" != 1 ] || exit 96
    printf '%s\n' stopped > "$state/$session"
    [ -z "${FM_FAKE_HERDR_ON_STOP:-}" ] || mutate_others "$FM_FAKE_HERDR_ON_STOP"
    [ -z "${FM_FAKE_HERDR_DEFAULT_ON_STOP:-}" ] || printf '%s\n' true > "$state/default-flag.$session"
    ;;
  "session delete")
    ! not_ours "$3" || violation "deleted a session the helper did not create"
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    [ -z "${FM_FAKE_HERDR_ON_DELETE:-}" ] || mutate_others "$FM_FAKE_HERDR_ON_DELETE"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# FM_FAKE_HERDR_FAST_POLL=1 makes the helper's waits instant for cases whose
# subject is not timing.
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
chmod +x "$FAKEBIN/sleep"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

# run_with_fake runs a helper function the way a worker inside the fleet pane
# would, with that pane's whole inherited Herdr identity exported.
run_with_fake() {
  HERDR_ENV=1 HERDR_PANE_ID=wC8:p2 HERDR_SESSION=fleet-e HERDR_SOCKET_PATH="$FLEET_E_SOCKET" \
    HERDR_TAB_ID=wC8:t2 HERDR_WORKSPACE_ID=wC8 \
    PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_STOP_FAIL="${FM_FAKE_HERDR_STOP_FAIL:-}" \
    FM_FAKE_HERDR_LIST_MODE="${FM_FAKE_HERDR_LIST_MODE:-}" \
    FM_FAKE_HERDR_ON_STOP="${FM_FAKE_HERDR_ON_STOP:-}" \
    FM_FAKE_HERDR_ON_DELETE="${FM_FAKE_HERDR_ON_DELETE:-}" \
    FM_FAKE_HERDR_DEFAULT_ON_STOP="${FM_FAKE_HERDR_DEFAULT_ON_STOP:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

fast() {
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake "$@"
}

session_json() { # <name> <default> <running> <socket>
  jq -nc --arg name "$1" --argjson default "$2" --argjson running "$3" --arg socket "$4" \
    '{default:$default,name:$name,running:$running,socket_path:$socket}'
}

# set_fleet <layout>: replace every session the helper did not create.
#   old       the fleet runs in a running `default` session (Linux CI layout)
#   mac       the fleet runs in `fleet-e` while `default` exists but is stopped
#   two       two fleet sessions run, `default` and `fleet-e`
#   stopped   only a stopped `default` session exists
#   empty     no session exists at all
#   labs-only only another process's lab runs, beside a stopped `default`
set_fleet() { # <layout>
  local default_running default_stopped fleet_e other_lab
  default_running=$(session_json default true true "$DEFAULT_SOCKET")
  default_stopped=$(session_json default true false "$DEFAULT_SOCKET")
  fleet_e=$(session_json fleet-e false true "$FLEET_E_SOCKET")
  other_lab=$(session_json fm-lab-concurrent-1 false true /tmp/fm-lab-concurrent-1.sock)
  case "$1" in
    old) printf '[%s]\n' "$default_running" ;;
    mac) printf '[%s,%s]\n' "$default_stopped" "$fleet_e" ;;
    two) printf '[%s,%s]\n' "$fleet_e" "$default_running" ;;
    stopped) printf '[%s]\n' "$default_stopped" ;;
    empty) printf '[]\n' ;;
    labs-only) printf '[%s,%s]\n' "$default_stopped" "$other_lab" ;;
    *) fail "unknown fleet layout: $1" ;;
  esac > "$FAKE_STATE/others.json"
}

others_mutate() { # <jq filter>
  jq -c "$1" "$FAKE_STATE/others.json" > "$FAKE_STATE/others.json.tmp" \
    || fail "could not mutate the fake's sessions with: $1"
  mv "$FAKE_STATE/others.json.tmp" "$FAKE_STATE/others.json"
}

# fleet_change <kind> <session>: one way a recorded fleet session can change.
fleet_change() { # <stop|disappear|socket> <session>
  case "$1" in
    stop) others_mutate "map(if .name == \"$2\" then .running = false else . end)" ;;
    disappear) others_mutate "map(select(.name != \"$2\"))" ;;
    socket) others_mutate "map(if .name == \"$2\" then .socket_path = \"/changed/$2.sock\" else . end)" ;;
    *) fail "unknown fleet change: $1" ;;
  esac
}

recorded_names() { # <lab>
  jq -r '[.[].name] | join(" ")' "$TRIPWIRES/$1.fleet-state.json"
}

# assert_never_touched_others <lab> <label>: the only destructive calls the
# helper made since the log was cleared named <lab>, and the fake saw no call
# scoped to, stopping, or deleting a session the helper did not create.
assert_never_touched_others() { # <lab> <label>
  local lab=$1 line
  while IFS= read -r line; do
    case "$line" in
      "session stop $lab --json --session $lab"|"session delete $lab --json --session $lab") : ;;
      "session stop"*|"session delete"*|"server stop"*|"server live-handoff"*)
        fail "$2: destructive call outside lab '$lab': $line" ;;
    esac
  done < "$FAKE_LOG"
  [ ! -s "$FAKE_STATE/violations" ] \
    || fail "$2: the helper acted on a session it did not create: $(cat "$FAKE_STATE/violations")"
}

set_fleet old

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  fleet_change socket default
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  set_fleet old
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_child_argv_delimiter_keeps_isolation() {
  local name status=0 line
  name="fm-lab-ddsplit-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  # An `agent start ... -- <child argv>` shape previously received --session
  # AFTER the delimiter: herdr never saw the flag (env-only isolation, which
  # the brief contract rejects) and the stray tokens joined the child argv,
  # silently on both counts (#1575).
  run_with_fake fm_herdr_lab_cli "$name" agent start worker --cwd /tmp -- echo hello >/dev/null || status=$?
  expect_code 0 "$status" "a -- subcommand must still run"
  line=$(grep 'agent start' "$FAKE_LOG" | tail -1)
  case "$line" in
    *"--session $name -- echo hello")
      : ;;
    *)
      fail "--session must precede the -- delimiter with the child argv intact, got: $line" ;;
  esac
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown failed"
  pass "fm-herdr-lab: --session precedes the child-argv delimiter, child argv unchanged"
}

# Gap 1: provision works when the fleet runs in a non-default session while
# `default` is stopped, when it runs in `default`, and with two fleet sessions.
test_provisions_whatever_the_fleet_session_is_called() {
  local layout expected name
  for layout in mac old two; do
    case "$layout" in
      mac) expected=fleet-e ;;
      old) expected=default ;;
      two) expected="default fleet-e" ;;
    esac
    set_fleet "$layout"
    name="fm-lab-layout-$layout-$$"
    : > "$FAKE_LOG"
    fast fm_herdr_lab_provision "$name" || fail "$layout layout: provision failed"
    [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "$layout layout: provision did not start the lab"
    [ "$(recorded_names "$name")" = "$expected" ] \
      || fail "$layout layout: tripwire recorded '$(recorded_names "$name")', expected '$expected'"
    fast fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "$layout layout: run failed"
    fast fm_herdr_lab_teardown "$name" || fail "$layout layout: teardown of an unchanged fleet failed"
    [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "$layout layout: teardown did not delete the lab"
    assert_absent "$TRIPWIRES/$name.fleet-state.json" "$layout layout: teardown left its tripwire behind"
    assert_never_touched_others "$name" "$layout layout"
  done
  set_fleet old
  pass "fm-herdr-lab: provision records the running fleet in a non-default session, in default, or in both"
}

# Gap 2: teardown fails loudly when any recorded fleet session stops,
# disappears, or changes its socket path, in either layout and with two fleet
# sessions, including the second of two.
test_teardown_trips_on_any_recorded_fleet_change() {
  local case_spec layout target change name status err
  err="$TMP_ROOT/teardown-trip.err"
  for case_spec in mac:fleet-e old:default two:default two:fleet-e; do
    layout=${case_spec%%:*}
    target=${case_spec#*:}
    for change in stop disappear socket; do
      set_fleet "$layout"
      name="fm-lab-trip-$layout-$change-$$"
      : > "$FAKE_LOG"
      fast fm_herdr_lab_provision "$name" || fail "$layout/$target/$change: provision failed"
      fleet_change "$change" "$target"
      status=0
      fast fm_herdr_lab_teardown "$name" >/dev/null 2>"$err" || status=$?
      expect_code 1 "$status" "$layout/$target/$change: teardown must fail"
      assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" \
        "$layout/$target/$change: teardown failure did not name the fleet tripwire"
      assert_present "$TRIPWIRES/$name.fleet-state.json" \
        "$layout/$target/$change: failed tripwire must retain its record as evidence"
      [ "$(cat "$FAKE_STATE/$name")" = deleted ] \
        || fail "$layout/$target/$change: teardown left the lab session behind"
      assert_never_touched_others "$name" "$layout/$target/$change"
      rm -f "$TRIPWIRES/$name.fleet-state.json"
    done
  done
  set_fleet old
  pass "fm-herdr-lab: teardown fails loudly on any stopped, missing, or re-socketed fleet session"
}

# A fleet session that stops after the lab's stop and is back before the final
# check still fails teardown, because the check after the stop saw it.
test_teardown_trips_on_transient_fleet_change() {
  local name="fm-lab-transient-$$" status=0 err="$TMP_ROOT/transient.err"
  set_fleet mac
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "transient fixture provision failed"
  FM_FAKE_HERDR_ON_STOP='map(if .name == "fleet-e" then .running = false else . end)' \
    FM_FAKE_HERDR_ON_DELETE='map(if .name == "fleet-e" then .running = true else . end)' \
    fast fm_herdr_lab_teardown "$name" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a fleet change seen after the lab's stop must fail teardown"
  assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" "transient change did not name the fleet tripwire"
  assert_grep "the fleet-state check after its stop failed" "$err" "transient change did not explain the failed teardown"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "transient change left the lab session behind"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "transient change removed the tripwire evidence"
  jq -e 'any(.[]; .name == "fleet-e" and .running == true)' "$FAKE_STATE/others.json" >/dev/null \
    || fail "fixture did not restore fleet-e before the final check"
  assert_never_touched_others "$name" "transient change"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  set_fleet old
  pass "fm-herdr-lab: a fleet change after the lab's stop fails teardown even once restored"
}

# Teardown's final check after the delete still guards the fleet: a recorded
# fleet session that stops while the lab is deleted fails teardown loudly even
# though the check after the lab's stop passed.
test_teardown_trips_on_fleet_change_during_delete() {
  local case_spec layout target name status err="$TMP_ROOT/delete-trip.err"
  for case_spec in mac:fleet-e old:default two:fleet-e; do
    layout=${case_spec%%:*}
    target=${case_spec#*:}
    set_fleet "$layout"
    name="fm-lab-delete-trip-$layout-$$"
    : > "$FAKE_LOG"
    fast fm_herdr_lab_provision "$name" || fail "$layout: delete-trip fixture provision failed"
    status=0
    FM_FAKE_HERDR_ON_DELETE="map(if .name == \"$target\" then .running = false else . end)" \
      fast fm_herdr_lab_teardown "$name" >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "$layout: a fleet change during the lab's delete must fail teardown"
    assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" \
      "$layout: a fleet change during the delete did not name the fleet tripwire"
    assert_no_grep "the fleet-state check after its stop failed" "$err" \
      "$layout: the fixture changed the fleet before the delete, so the final check went untested"
    [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "$layout: teardown left the lab session behind"
    assert_present "$TRIPWIRES/$name.fleet-state.json" \
      "$layout: a fleet change during the delete removed the tripwire evidence"
    assert_never_touched_others "$name" "$layout delete-time change"
    rm -f "$TRIPWIRES/$name.fleet-state.json"
  done
  set_fleet old
  pass "fm-herdr-lab: teardown's final check fails loudly on a fleet change during the lab's delete"
}

# The fleet check after a guarded stop fails loudly in every layout, and the
# retained record still guards a later teardown once the fleet is back.
test_guarded_stop_trips_on_fleet_change() {
  local case_spec layout target name status err="$TMP_ROOT/stop-trip.err"
  for case_spec in mac:fleet-e old:default two:fleet-e; do
    layout=${case_spec%%:*}
    target=${case_spec#*:}
    set_fleet "$layout"
    name="fm-lab-stop-trip-$layout-$$"
    : > "$FAKE_LOG"
    fast fm_herdr_lab_provision "$name" || fail "$layout: stop fixture provision failed"
    fleet_change stop "$target"
    status=0
    fast fm_herdr_lab_stop "$name" >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "$layout: guarded stop must fail when $target stopped"
    assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" "$layout: guarded stop failure did not name the fleet tripwire"
    [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "$layout: guarded stop did not stop the lab"
    assert_present "$TRIPWIRES/$name.fleet-state.json" "$layout: guarded stop failure removed the tripwire"
    set_fleet "$layout"
    fast fm_herdr_lab_teardown "$name" || fail "$layout: teardown after the fleet was restored failed"
    assert_never_touched_others "$name" "$layout guarded stop"
  done
  set_fleet old
  pass "fm-herdr-lab: guarded stop fails loudly when a recorded fleet session changed"
}

# A failed Herdr stop still gets the fleet check: guarded stop returns Herdr's
# own failure status when the fleet is unchanged, and fails the tripwire when
# it is not.
test_guarded_stop_reports_a_failed_stop() {
  local name="fm-lab-stop-fail-$$" status=0 err="$TMP_ROOT/stop-fail.err"
  set_fleet mac
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "stop-failure fixture provision failed"
  FM_FAKE_HERDR_STOP_FAIL=1 fast fm_herdr_lab_stop "$name" >/dev/null 2>"$err" || status=$?
  expect_code 96 "$status" "guarded stop must return the failed Herdr stop's own status"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "the failed-stop fixture changed the lab"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "a failed guarded stop dropped the tripwire"
  fleet_change stop fleet-e
  status=0
  FM_FAKE_HERDR_STOP_FAIL=1 fast fm_herdr_lab_stop "$name" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a failed guarded stop must still fail on a fleet change"
  assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" "a failed guarded stop skipped the fleet check"
  set_fleet mac
  fast fm_herdr_lab_teardown "$name" || fail "teardown after a failed guarded stop failed"
  assert_never_touched_others "$name" "failed guarded stop"
  set_fleet old
  pass "fm-herdr-lab: guarded stop reports a failed Herdr stop after checking the fleet"
}

test_reordered_listing_is_not_a_fleet_change() {
  local name="fm-lab-reorder-$$"
  set_fleet two
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "reorder fixture provision failed"
  others_mutate 'reverse'
  fast fm_herdr_lab_teardown "$name" || fail "Herdr listing the same fleet in another order failed teardown"
  set_fleet old
  pass "fm-herdr-lab: the fleet record does not depend on Herdr's listing order"
}

# Gap 3: provision refuses, without starting anything or keeping a record,
# when no session outside the lab namespace is running or the list is unusable.
test_provision_refuses_without_a_running_fleet() {
  local spec layout mode expect name status err="$TMP_ROOT/no-fleet.err" verb
  for spec in stopped:: empty:: labs-only:: mac:fail:'cannot list Herdr sessions' mac:garbage:'cannot parse' \
    mac:multi:'cannot parse'; do
    layout=${spec%%:*}
    mode=${spec#*:}
    mode=${mode%%:*}
    expect=${spec#*:*:}
    [ -n "$expect" ] || expect="requires at least one running Herdr session whose name does not begin with 'fm-lab-'"
    for verb in provision prepare; do
      set_fleet "$layout"
      name="fm-lab-nofleet-$layout-$verb-$$"
      : > "$FAKE_LOG"
      status=0
      FM_FAKE_HERDR_LIST_MODE=$mode fast "fm_herdr_lab_$verb" "$name" >/dev/null 2>"$err" || status=$?
      expect_code 1 "$status" "$layout${mode:+/$mode}: $verb must refuse"
      assert_grep "$expect" "$err" "$layout${mode:+/$mode}: $verb refused without the expected reason"
      assert_absent "$TRIPWIRES/$name.fleet-state.json" "$layout${mode:+/$mode}: $verb kept a tripwire"
      assert_absent "$FAKE_STATE/$name" "$layout${mode:+/$mode}: $verb created the lab session"
      assert_no_grep "server --session" "$FAKE_LOG" "$layout${mode:+/$mode}: $verb started a server"
      assert_never_touched_others "$name" "$layout${mode:+/$mode} $verb"
    done
  done
  set_fleet old
  pass "fm-herdr-lab: provision refuses when no session outside the lab namespace is running"
}

# Gap 4: a name that is not a lab name, including every fleet session's name,
# is refused before any Herdr call, and a lab session the helper did not create
# is never adopted, stopped, or deleted.
test_never_acts_on_sessions_it_did_not_create() {
  local bad verb status foreign="fm-lab-foreign-$$" before running
  set_fleet two
  for bad in fleet-e default '' fm-lab- fm-labx FM-LAB-x 'fm-lab-a b' 'fm-lab-../x' x-fm-lab-y; do
    for verb in prepare provision stop teardown; do
      : > "$FAKE_LOG"
      status=0
      fast "fm_herdr_lab_$verb" "$bad" >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "$verb must refuse name '$bad'"
      [ ! -s "$FAKE_LOG" ] || fail "$verb '$bad' reached Herdr: $(cat "$FAKE_LOG")"
    done
    : > "$FAKE_LOG"
    status=0
    fast fm_herdr_lab_cli "$bad" workspace list >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "run must refuse name '$bad'"
    [ ! -s "$FAKE_LOG" ] || fail "run '$bad' reached Herdr: $(cat "$FAKE_LOG")"
  done
  : > "$FAKE_LOG"
  status=0
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$FAKE_STATE" FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" "$ROOT/bin/fm-herdr-lab.sh" teardown fleet-e >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "the script entry point must refuse a fleet session name"
  [ ! -s "$FAKE_LOG" ] || fail "the script entry point reached Herdr for a fleet name"

  others_mutate "$(printf '. + [{default:false,name:"%s",running:true,socket_path:"/tmp/%s.sock"}]' "$foreign" "$foreign")"
  for running in true false; do
    others_mutate "map(if .name == \"$foreign\" then .running = $running else . end)"
    before=$(cat "$FAKE_STATE/others.json")
    : > "$FAKE_LOG"
    for verb in prepare provision; do
      status=0
      fast "fm_herdr_lab_$verb" "$foreign" >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "$verb must refuse to adopt a lab it did not create (running=$running)"
    done
    assert_no_grep "server --session" "$FAKE_LOG" "a refusal started a server for the foreign lab (running=$running)"
    for verb in stop teardown; do
      : > "$FAKE_LOG"
      status=0
      fast "fm_herdr_lab_$verb" "$foreign" >/dev/null 2>&1 || status=$?
      expect_code 1 "$status" "$verb must refuse a lab it did not create (running=$running)"
      [ ! -s "$FAKE_LOG" ] || fail "$verb of a foreign lab reached Herdr: $(cat "$FAKE_LOG")"
    done
    [ "$(cat "$FAKE_STATE/others.json")" = "$before" ] || fail "the foreign lab changed (running=$running)"
    assert_absent "$TRIPWIRES/$foreign.fleet-state.json" "refusals left a tripwire for the foreign lab"
    assert_never_touched_others "$foreign" "foreign lab (running=$running)"
  done
  set_fleet old
  pass "fm-herdr-lab: fleet names and labs it did not create are refused before any destructive call"
}

# Gap 5: neither this lab, created during provision, nor any concurrent lab
# counts as fleet, and concurrent labs are never touched.
test_lab_sessions_never_count_as_fleet() {
  local name="fm-lab-own-$$" third="fm-lab-concurrent-3"
  set_fleet mac
  others_mutate '. + [{default:false,name:"fm-lab-concurrent-1",running:true,socket_path:"/tmp/fm-lab-concurrent-1.sock"},{default:false,name:"fm-lab-concurrent-2",running:false,socket_path:"/tmp/fm-lab-concurrent-2.sock"}]'
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "provision beside concurrent labs failed"
  [ "$(recorded_names "$name")" = fleet-e ] \
    || fail "tripwire counted a lab session as fleet: $(recorded_names "$name")"
  fast fm_herdr_lab_check_tripwire "$name" || fail "this running lab was counted as fleet after provision"
  others_mutate 'map(if .name == "fm-lab-concurrent-1" then .running = false else . end)'
  others_mutate "map(select(.name != \"fm-lab-concurrent-2\")) + [{default:false,name:\"$third\",running:true,socket_path:\"/tmp/$third.sock\"}]"
  fast fm_herdr_lab_stop "$name" >/dev/null || fail "guarded stop counted a concurrent or stopped lab as fleet"
  fast fm_herdr_lab_provision "$name" || fail "re-provision counted a concurrent lab as fleet"
  fast fm_herdr_lab_teardown "$name" || fail "teardown counted a concurrent lab as fleet"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "teardown beside concurrent labs left its tripwire"
  jq -e --arg third "$third" 'any(.[]; .name == $third and .running == true)' "$FAKE_STATE/others.json" >/dev/null \
    || fail "a concurrent lab changed during this lab's lifecycle"
  assert_never_touched_others "$name" "concurrent labs"
  set_fleet old
  pass "fm-herdr-lab: this lab and concurrent labs never count as fleet and are never touched"
}

# A worker inside a fleet pane inherits that pane's socket path and ids; the
# helper must route every lab call by --session alone, through a whole lab
# lifecycle including a guarded stop and re-provision.
test_drops_inherited_fleet_pane_identity() {
  local name="fm-lab-inherited-$$"
  set_fleet mac
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "provision from inside a fleet pane failed"
  fast fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "run from inside a fleet pane failed"
  fast fm_herdr_lab_stop "$name" >/dev/null || fail "guarded stop from inside a fleet pane failed"
  fast fm_herdr_lab_provision "$name" || fail "re-provision from inside a fleet pane failed"
  fast fm_herdr_lab_teardown "$name" || fail "teardown from inside a fleet pane failed"
  assert_grep "server --session $name" "$FAKE_LOG" "the lifecycle never reached the lab server"
  assert_never_touched_others "$name" "inherited fleet pane identity"
  set_fleet old
  pass "fm-herdr-lab: a caller's inherited fleet pane identity never reaches Herdr"
}

# Refuse-default runs immediately before each destructive call: a lab Herdr
# reports as the default session is never stopped or deleted, whether it reads
# default before the stop or turns default between the stop and the delete.
test_destructive_calls_refuse_a_default_flagged_lab() {
  local name="fm-lab-default-flag-$$" verb status err="$TMP_ROOT/default-flag.err"
  set_fleet mac
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "default-flag fixture provision failed"
  printf '%s\n' true > "$FAKE_STATE/default-flag.$name"
  for verb in stop teardown; do
    : > "$FAKE_LOG"
    status=0
    fast "fm_herdr_lab_$verb" "$name" >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "guarded $verb must refuse a lab Herdr reports as default"
    assert_grep "refusing destructive call for '$name'" "$err" \
      "guarded $verb refused a default-flagged lab without the refuse-default reason"
    assert_no_grep "session stop " "$FAKE_LOG" "guarded $verb stopped a lab Herdr reports as default"
    assert_no_grep "session delete " "$FAKE_LOG" "guarded $verb deleted a lab Herdr reports as default"
    [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "guarded $verb changed a lab Herdr reports as default"
    assert_present "$TRIPWIRES/$name.fleet-state.json" "guarded $verb dropped a default-flagged lab's tripwire"
  done
  rm -f "$FAKE_STATE/default-flag.$name"
  : > "$FAKE_LOG"
  status=0
  FM_FAKE_HERDR_DEFAULT_ON_STOP=1 fast fm_herdr_lab_teardown "$name" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "teardown must refuse to delete a lab that turned default after its stop"
  assert_grep "refusing destructive call for '$name'" "$err" \
    "teardown refused a lab that turned default without the refuse-default reason"
  assert_no_grep "session delete " "$FAKE_LOG" "teardown deleted a lab that turned default after its stop"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "teardown did not leave the lab that turned default stopped"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "teardown dropped the tripwire of a lab that turned default"
  rm -f "$FAKE_STATE/default-flag.$name"
  : > "$FAKE_LOG"
  fast fm_herdr_lab_teardown "$name" || fail "teardown once the lab no longer reads default failed"
  assert_never_touched_others "$name" "default-flagged lab"
  set_fleet old
  pass "fm-herdr-lab: a lab Herdr reports as default is never stopped or deleted"
}

# A running session listed without a string name is recorded as fleet rather
# than escaping the record, so its stopping still trips teardown.
test_nameless_running_session_counts_as_fleet() {
  local name="fm-lab-nameless-$$" status=0 err="$TMP_ROOT/nameless.err"
  set_fleet mac
  others_mutate '. + [{default:false,running:true,socket_path:"/tmp/nameless.sock"}]'
  : > "$FAKE_LOG"
  fast fm_herdr_lab_provision "$name" || fail "provision beside a nameless running session failed"
  jq -e 'length == 2 and any(.[]; .name == null and .socket_path == "/tmp/nameless.sock")' \
    "$TRIPWIRES/$name.fleet-state.json" >/dev/null \
    || fail "the tripwire did not record a nameless running session as fleet: $(cat "$TRIPWIRES/$name.fleet-state.json")"
  others_mutate 'map(if .name == null then .running = false else . end)'
  fast fm_herdr_lab_teardown "$name" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a nameless fleet session that stopped must fail teardown"
  assert_grep "FLEET-STATE TRIPWIRE FAILED" "$err" "a stopped nameless fleet session did not name the fleet tripwire"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown beside a nameless session left the lab behind"
  assert_never_touched_others "$name" "nameless fleet session"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  set_fleet old
  pass "fm-herdr-lab: a running session without a name counts as fleet"
}

test_no_case_reached_a_session_it_did_not_create() {
  [ ! -s "$FAKE_STATE/violations" ] \
    || fail "a case made a call the helper must never make: $(cat "$FAKE_STATE/violations")"
  pass "fm-herdr-lab: no case leaked identity to, or acted on, a session the helper did not create"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_child_argv_delimiter_keeps_isolation
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
test_provisions_whatever_the_fleet_session_is_called
test_teardown_trips_on_any_recorded_fleet_change
test_teardown_trips_on_transient_fleet_change
test_teardown_trips_on_fleet_change_during_delete
test_guarded_stop_trips_on_fleet_change
test_guarded_stop_reports_a_failed_stop
test_reordered_listing_is_not_a_fleet_change
test_provision_refuses_without_a_running_fleet
test_never_acts_on_sessions_it_did_not_create
test_lab_sessions_never_count_as_fleet
test_drops_inherited_fleet_pane_identity
test_destructive_calls_refuse_a_default_flagged_lab
test_nameless_running_session_counts_as_fleet
test_no_case_reached_a_session_it_did_not_create
